#pragma once
#include <inttypes.h>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>

#define CHUNK_SIZE 16

namespace cudarrows {
    enum ArrowType : uint8_t {
        Void,
        ArrowUp,
        Source,
        Blocker,
        Delay,
        Detector,
        ArrowUpDown,
        ArrowUpRight,
        ArrowUpLeftRight,
        Pulse,
        ArrowUp2,
        ArrowDiagonal,
        ArrowUp2Up,
        ArrowUp2Right,
        ArrowUpDiagonal,
        Not,
        And,
        Xor,
        Latch,
        Flipflop,
        Randomizer,
        ButtonUpDownLeftRight,
        ButtonUp
    };

    enum ArrowRotation : uint8_t {
        North,
        East,
        South,
        West
    };

    enum ArrowSignal : uint8_t {
        White,
        Red,
        Blue,
        Yellow,
        Green,
        Orange,
        Magenta
    };

    struct Arrow {
        ArrowType type = ArrowType::Void;
        ArrowRotation rotation = ArrowRotation::North;
        bool flipped = false;
    };

    struct ArrowState {
        ArrowSignal signal = ArrowSignal::White;
        uint8_t signalCount = 0;
        bool blocked = false;
    };

    struct Chunk {
        uint16_t x, y;
        Chunk *adjacentChunks[8] = { nullptr };
        Arrow arrows[CHUNK_SIZE * CHUNK_SIZE];
        ArrowState states[CHUNK_SIZE * CHUNK_SIZE][2];

        Chunk(uint16_t x, uint16_t y) : x(x), y(y) {}

        Chunk() : Chunk(0, 0) {}
    };

    class Map {
    private:
        thrust::device_vector<Chunk> chunks;
        
    public:
        Map() {}

        void load(const std::string &save);
        
        std::string save();

        const Chunk *getChunks() const { return thrust::raw_pointer_cast(chunks.data()); };

        size_t countChunks() const { return chunks.size(); };

        const Chunk getChunk(uint16_t x, uint16_t y);

        void setChunk(uint16_t x, uint16_t y, Chunk chunk);

        const Arrow getArrow(uint32_t x, uint32_t y);

        void setArrow(uint32_t x, uint32_t y, Arrow arrow);
    };
};