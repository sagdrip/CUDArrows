#include <curand_kernel.h>
#include "chunkupdates.cuh"
#include "util/atomic_uint8.cuh"

__device__ cudarrows::Arrow *getArrow(cudarrows::Chunk *chunks, cudarrows::Chunk &chunk, cudarrows::Arrow &arrow, uint3 pos, cudarrows::localCoord dx, cudarrows::localCoord dy) {
    if (arrow.flipped)
        dx = -dx;
    int16_t x = pos.x;
    int16_t y = pos.y;
    switch (arrow.rotation) {
        case cudarrows::ArrowRotation::North:
            y += dy;
            x += dx;
            break;
        case cudarrows::ArrowRotation::East:
            x -= dy;
            y += dx;
            break;
        case cudarrows::ArrowRotation::South:
            y -= dy;
            x -= dx;
            break;
        case cudarrows::ArrowRotation::West:
            x += dy;
            y -= dx;
            break;
    }
    cudarrows::Chunk *targetChunk = &chunk;
    if (x >= CHUNK_SIZE) {
        if (y >= CHUNK_SIZE) {
            targetChunk = chunk.adjacentChunks[3];
            x -= CHUNK_SIZE;
            y -= CHUNK_SIZE;
      }  else if (y < 0) {
            targetChunk = chunk.adjacentChunks[1];
            x -= CHUNK_SIZE;
            y += CHUNK_SIZE;
        } else {
            targetChunk = chunk.adjacentChunks[2];
            x -= CHUNK_SIZE;
        }
    } else if (x < 0) {
        if (y < 0) {
            targetChunk = chunk.adjacentChunks[7];
            x += CHUNK_SIZE;
            y += CHUNK_SIZE;
        } else if (y >= CHUNK_SIZE) {
            targetChunk = chunk.adjacentChunks[5];
            x += CHUNK_SIZE;
            y -= CHUNK_SIZE;
        } else {
            targetChunk = chunk.adjacentChunks[6];
            x += CHUNK_SIZE;
        }
    } else if (y < 0) {
        targetChunk = chunk.adjacentChunks[0];
        y += CHUNK_SIZE;
    } else if (y >= CHUNK_SIZE) {
        targetChunk = chunk.adjacentChunks[4];
        y -= CHUNK_SIZE;
    }
    return targetChunk == nullptr ? nullptr : &targetChunk->arrows[y * CHUNK_SIZE + x];
}

__device__ void sendSignal(cudarrows::Arrow *arrow, uint8_t step) {
    if (arrow && arrow->type != cudarrows::ArrowType::Void)
        atomicAdd(&arrow->state[step].signalCount, (uint8_t)1U);
}

__device__ void blockSignal(cudarrows::Arrow *arrow, uint8_t step) {
    if (arrow && arrow->type != cudarrows::ArrowType::Void)
        arrow->state[step].blocked = true;
}

__global__ void update(cudarrows::Chunk *chunks, uint8_t step, uint8_t nextStep) {
    cudarrows::Chunk &chunk = chunks[blockIdx.x];
    cudarrows::arrowIdx idx = threadIdx.y * CHUNK_SIZE + threadIdx.x;
    cudarrows::Arrow &arrow = chunk.arrows[idx];
    cudarrows::ArrowState &state = arrow.state[step];
    cudarrows::ArrowState &prevState = arrow.state[nextStep];
    switch (arrow.type) {
        case cudarrows::ArrowType::Arrow:
        case cudarrows::ArrowType::Blocker:
        case cudarrows::ArrowType::SplitterUpDown:
        case cudarrows::ArrowType::SplitterUpRight:
        case cudarrows::ArrowType::SplitterUpLeftRight:
        case cudarrows::ArrowType::Source:
        case cudarrows::ArrowType::Target:
            state.signal = state.signalCount > 0 ? cudarrows::ArrowSignal::Red : cudarrows::ArrowSignal::White;
            break;
        case cudarrows::ArrowType::SourceBlock:
            state.signal = cudarrows::ArrowSignal::Red;
            break;
        case cudarrows::ArrowType::DelayArrow:
            if (state.signalCount > 0)
                state.signal = prevState.signal == cudarrows::ArrowSignal::White ? cudarrows::ArrowSignal::Blue : cudarrows::ArrowSignal::Red;
            else
                state.signal = prevState.signal == cudarrows::ArrowSignal::Blue ? cudarrows::ArrowSignal::Red : cudarrows::ArrowSignal::White;
            break;
        case cudarrows::ArrowType::SignalDetector: {
            cudarrows::Arrow *arrowBehind = getArrow(chunks, chunk, arrow, threadIdx, 0, 1);
            state.signal =
                arrowBehind == nullptr || arrowBehind->state[nextStep].signal == cudarrows::ArrowSignal::White ?
                    cudarrows::ArrowSignal::White :
                    cudarrows::ArrowSignal::Red;
            break;   
        }
        case cudarrows::ArrowType::PulseGenerator:
            state.signal = prevState.signal == cudarrows::ArrowSignal::White ? cudarrows::ArrowSignal::Red : cudarrows::ArrowSignal::Blue;
            break;
        case cudarrows::ArrowType::BlueArrow:
        case cudarrows::ArrowType::DiagonalArrow:
        case cudarrows::ArrowType::BlueSplitterUpUp:
        case cudarrows::ArrowType::BlueSplitterUpRight:
        case cudarrows::ArrowType::BlueSplitterUpDiagonal:
            state.signal = state.signalCount > 0 ? cudarrows::ArrowSignal::Blue : cudarrows::ArrowSignal::White;
            break;
        case cudarrows::ArrowType::NotGate:
            state.signal = state.signalCount == 0 ? cudarrows::ArrowSignal::Yellow : cudarrows::ArrowSignal::White;
            break;
        case cudarrows::ArrowType::AndGate:
            state.signal = state.signalCount >= 2 ? cudarrows::ArrowSignal::Yellow : cudarrows::ArrowSignal::White;
            break;
        case cudarrows::ArrowType::XorGate:
            state.signal = state.signalCount % 2 == 1 ? cudarrows::ArrowSignal::Yellow : cudarrows::ArrowSignal::White;
            break;
        case cudarrows::ArrowType::Latch:
            state.signal =
                state.signalCount > 0 ?
                    state.signalCount >= 2 ? cudarrows::ArrowSignal::Yellow : cudarrows::ArrowSignal::White :
                    prevState.signal;
            break;
        case cudarrows::ArrowType::Flipflop:
            state.signal =
                state.signalCount > 0 ?
                    (cudarrows::ArrowSignal)((uint8_t)cudarrows::ArrowSignal::Yellow - (uint8_t)prevState.signal) :
                    prevState.signal;
            break;
        case cudarrows::ArrowType::Randomizer:
            state.signal =
                state.signalCount > 0 && curand(&arrow.input.curandState) > 2147483647 ?
                    cudarrows::ArrowSignal::Orange :
                    cudarrows::ArrowSignal::White;
            break;
        case cudarrows::ArrowType::Button:
            state.signal = arrow.input.buttonPressed ? cudarrows::ArrowSignal::Orange : cudarrows::ArrowSignal::White;
            arrow.input.buttonPressed = false;
            break;
        case cudarrows::ArrowType::DirectionalButton:
            state.signal = arrow.input.buttonPressed || state.signalCount > 0 ? cudarrows::ArrowSignal::Orange : cudarrows::ArrowSignal::White;
            arrow.input.buttonPressed = false;
            break;
    }
    if (state.blocked)
        state.signal = cudarrows::ArrowSignal::White;
    switch (arrow.type) {
        case cudarrows::ArrowType::Arrow:
        case cudarrows::ArrowType::DelayArrow:
        case cudarrows::ArrowType::SignalDetector:
        case cudarrows::ArrowType::Source:
            if (state.signal == cudarrows::ArrowSignal::Red)
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -1), nextStep);
            break;
        case cudarrows::ArrowType::SourceBlock:
        case cudarrows::ArrowType::PulseGenerator:
            if (state.signal == cudarrows::ArrowSignal::Red) {
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx,  0, -1), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx,  1,  0), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx,  0,  1), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, -1,  0), nextStep);
            }
            break;
        case cudarrows::ArrowType::Blocker:
            if (state.signal == cudarrows::ArrowSignal::Red)
                blockSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -1), nextStep);
            break;
        case cudarrows::ArrowType::SplitterUpDown:
            if (state.signal == cudarrows::ArrowSignal::Red) {
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -1), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0,  1), nextStep);
            }
            break;
        case cudarrows::ArrowType::SplitterUpRight:
            if (state.signal == cudarrows::ArrowSignal::Red) {
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -1), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 1,  0), nextStep);
            }
            break;
        case cudarrows::ArrowType::SplitterUpLeftRight:
            if (state.signal == cudarrows::ArrowSignal::Red) {
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, -1,  0), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx,  0, -1), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx,  1,  0), nextStep);
            }
            break;
        case cudarrows::ArrowType::BlueArrow:
            if (state.signal == cudarrows::ArrowSignal::Blue)
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -2), nextStep);
            break;
        case cudarrows::ArrowType::DiagonalArrow:
            if (state.signal == cudarrows::ArrowSignal::Blue)
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 1, -1), nextStep);
            break;
        case cudarrows::ArrowType::BlueSplitterUpUp:
            if (state.signal == cudarrows::ArrowSignal::Blue) {
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -1), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -2), nextStep);
            }
            break;
        case cudarrows::ArrowType::BlueSplitterUpRight:
            if (state.signal == cudarrows::ArrowSignal::Blue) {
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -2), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 1,  0), nextStep);
            }
            break;
        case cudarrows::ArrowType::BlueSplitterUpDiagonal:
            if (state.signal == cudarrows::ArrowSignal::Blue) {
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -1), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 1, -1), nextStep);
            }
            break;
        case cudarrows::ArrowType::NotGate:
        case cudarrows::ArrowType::AndGate:
        case cudarrows::ArrowType::XorGate:
        case cudarrows::ArrowType::Latch:
        case cudarrows::ArrowType::Flipflop:
            if (state.signal == cudarrows::ArrowSignal::Yellow)
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -1), nextStep);
            break;
        case cudarrows::ArrowType::Randomizer:
        case cudarrows::ArrowType::DirectionalButton:
            if (state.signal == cudarrows::ArrowSignal::Orange)
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, 0, -1), nextStep);
            break;
        case cudarrows::ArrowType::Button:
            if (state.signal == cudarrows::ArrowSignal::Orange) {
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx,  0, -1), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx,  1,  0), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx,  0,  1), nextStep);
                sendSignal(getArrow(chunks, chunk, arrow, threadIdx, -1,  0), nextStep);
            }
            break;
    }
    state.signalCount = 0;
    state.blocked = false;
}

__global__ void reset(cudarrows::Chunk *chunks, uint64_t seed) {
    cudarrows::Chunk &chunk = chunks[blockIdx.x];
    cudarrows::arrowIdx idx = threadIdx.y * CHUNK_SIZE + threadIdx.x;
    cudarrows::Arrow &arrow = chunk.arrows[idx];
    arrow.state[blockIdx.y] = cudarrows::ArrowState();
    if (blockIdx.y == 0)
        switch (arrow.type) {
            case cudarrows::ArrowType::Button:
            case cudarrows::ArrowType::DirectionalButton:
                arrow.input.buttonPressed = false;
                break;
            case cudarrows::ArrowType::Randomizer: {
                unsigned long long subsequence = ((uint16_t)chunk.y << 24) | ((uint16_t)chunk.x << 8) | idx;
                curand_init(seed, subsequence, 0, &arrow.input.curandState);
                break;
            }
        }
}