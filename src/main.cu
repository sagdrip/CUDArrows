#include <exception>
#include <cstdlib>
#include <stdio.h>
#include <glad/glad.h>
#include <GLFW/glfw3.h>
#include <cuda_gl_interop.h>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>
#include "shaders/arrows.h"
#include "shaders/grid.h"
#include "camera.h"
#include "map.h"
#include "chunkupdates.h"
#include "render.h"

#define CELL_SIZE 64.0

float scroll = 0.0;

static void cudarrows_terminate() {
    try {
        if (std::current_exception())
            std::rethrow_exception(std::current_exception());
    } catch (const std::exception& e) {
        fprintf(stderr, "Error: %s\n", e.what());
    }
    abort();
}

static void glfw_error_callback(int error, const char* description) {
    fprintf(stderr, "GLFW Error %d: %s\n", error, description);
}

static void framebuffer_size_callback(GLFWwindow* window, int width, int height) {
    glViewport(0, 0, width, height);
}

static void scroll_callback(GLFWwindow *window, double xoffset, double yoffset) {
    scroll += static_cast<float>(yoffset);
}

static void cuda_check(const char *file, int line, cudaError_t error) {
    if (error != cudaError::cudaSuccess) {
        fprintf(stderr, "CUDA Error (%s:%d) %d: %s\n", file, line, error, cudaGetErrorString(error));
        abort();
    }
}

#define cuda_assert(error) cuda_check(__FILE__, __LINE__, error)

GLsizei roundToPowerOf2(GLsizei n) {
    --n;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    return ++n < 16 ? 16 : n;
}

int main(void) {
    std::set_terminate(cudarrows_terminate);

    /*cudaStream_t stream;
    cuda_assert(cudaStreamCreate(&stream));*/

    /*cudaEvent_t start, stop;
    cuda_assert(cudaEventCreate(&start));
    cuda_assert(cudaEventCreate(&stop));*/

    glfwSetErrorCallback(glfw_error_callback);
    if (!glfwInit()) {
        fprintf(stderr, "Failed to initialize GLFW\n");
        return 1;
    }

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 4);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 4);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

    glfwWindowHint(GLFW_OPENGL_DEBUG_CONTEXT, GLFW_TRUE);

    glfwWindowHint(GLFW_MAXIMIZED, GLFW_TRUE);

    GLFWwindow* window = glfwCreateWindow(1280, 720, "CUDArrows", nullptr, nullptr);
    if (window == nullptr)
        return 1;
    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    glfwSetFramebufferSizeCallback(window, framebuffer_size_callback);
    glfwSetScrollCallback(window, scroll_callback);

    if (!gladLoadGLLoader((GLADloadproc)glfwGetProcAddress)) {
        fprintf(stderr, "Failed to initialize GLAD\n");
        return 1;
    }

    glEnable(GL_DEBUG_OUTPUT);

    GLfloat vertices[] = {
        1.f, 1.f, 0.f, 1.f,
        1.f, 0.f, 0.f, 1.f,
        0.f, 0.f, 0.f, 1.f,
        0.f, 1.f, 0.f, 1.f,
    };

    GLuint indices[] = {
        0, 1, 3,
        1, 2, 3,
    };

    GLuint VBO, VAO, EBO;
    glGenVertexArrays(1, &VAO);
    glGenBuffers(1, &VBO);
    glGenBuffers(1, &EBO);
    glBindVertexArray(VAO);

    glBindBuffer(GL_ARRAY_BUFFER, VBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, EBO);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW); 

    glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, (void *)0);
    glEnableVertexAttribArray(0);

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    cudarrows::Map map;

    cudarrows::ArrowsShader arrows;
    cudarrows::GridShader grid;

    cudarrows::Camera camera(0.f, 0.f, 1.f);

    map.load("AAABAAAAAAAAAQAAAA==");

    double lastMouseX, lastMouseY;
    float lastCameraX, lastCameraY;

    uint8_t step = 0;

    glm::mat4 projection = glm::ortho(0.f, 1.f, 1.f, 0.f);

    arrows.use();
    arrows.projection.set(1, false, glm::value_ptr(projection));

    grid.use();
    grid.projection.set(1, false, glm::value_ptr(projection));

    cudaGraphicsResource_t cudaTexture = nullptr;

    GLuint dataTexture;

    uint8_t fill[4] = { 0, 0, 0, 1 };

    cudaResourceDesc resDesc;
    memset(&resDesc, 0, sizeof(resDesc));
    resDesc.resType = cudaResourceTypeArray;

    GLsizei texWidth, texHeight,
            lastSpanX, lastSpanY;

    while (!glfwWindowShouldClose(window)) {
        glfwPollEvents();
        if (glfwGetWindowAttrib(window, GLFW_ICONIFIED) != 0)
            continue;

        double mouseX, mouseY;
        glfwGetCursorPos(window, &mouseX, &mouseY);

        bool wheelDown = glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS;

        if (wheelDown) {
            camera.xOffset = static_cast<float>(lastCameraX + mouseX - lastMouseX);
            camera.yOffset = static_cast<float>(lastCameraY + mouseY - lastMouseY);
        }

        if (scroll > 0.0)
            camera.setScale(camera.getScale() * scroll * 1.2f, static_cast<float>(mouseX), static_cast<float>(mouseY));
        else if (scroll < 0.0)
            camera.setScale(camera.getScale() / -scroll / 1.2f, static_cast<float>(mouseX), static_cast<float>(mouseY));
        scroll = 0.0f;

        lastCameraX = camera.xOffset;
        lastCameraY = camera.yOffset;
        lastMouseX = mouseX;
        lastMouseY = mouseY;

        glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);

        int width, height;
        glfwGetFramebufferSize(window, &width, &height);

        int32_t minX = int32_t(-camera.xOffset / camera.getScale() / CELL_SIZE) - 1,
                minY = int32_t(-camera.yOffset / camera.getScale() / CELL_SIZE) - 1,
                maxX = int32_t((-camera.xOffset + width) / camera.getScale() / CELL_SIZE),
                maxY = int32_t((-camera.yOffset + height) / camera.getScale() / CELL_SIZE);
        
        GLsizei spanX = GLsizei(width / camera.getScale() / CELL_SIZE) + 2,
                spanY = GLsizei(height / camera.getScale() / CELL_SIZE) + 2;

        if (cudaTexture == nullptr || lastSpanX != spanX || lastSpanY != spanY) {
            lastSpanX = spanX;
            lastSpanY = spanY;

            GLsizei newTexWidth = roundToPowerOf2(spanX),
                    newTexHeight = roundToPowerOf2(spanY);
            if (cudaTexture == nullptr || newTexWidth != texWidth || newTexHeight != texHeight) {
                texWidth = newTexWidth;
                texHeight = newTexHeight;

                if (cudaTexture != nullptr) {
                    cuda_assert(cudaGraphicsUnregisterResource(cudaTexture));

                    glDeleteTextures(1, &dataTexture);
                }

                glGenTextures(1, &dataTexture);
                glBindTexture(GL_TEXTURE_2D, dataTexture);
                
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
                
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP);

                glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, texWidth, texHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
                glGenerateMipmap(GL_TEXTURE_2D);

                cuda_assert(cudaGraphicsGLRegisterImage(&cudaTexture, dataTexture, GL_TEXTURE_2D, cudaGraphicsRegisterFlagsSurfaceLoadStore));
            }
        }

        glClearTexImage(dataTexture, 0, GL_RGBA, GL_UNSIGNED_BYTE, &fill);

        cudaArray_t cuda_array;

        cuda_assert(cudaGraphicsMapResources(1, &cudaTexture));
        cuda_assert(cudaGraphicsSubResourceGetMappedArray(&cuda_array, cudaTexture, 0, 0));
        
        resDesc.res.array.array = cuda_array;
        cudaSurfaceObject_t surface;
        cuda_assert(cudaCreateSurfaceObject(&surface, &resDesc));

        render<<<map.countChunks(), dim3(CHUNK_SIZE, CHUNK_SIZE)>>>(surface, map.getChunks(), step, minX, minY, maxX, maxY);
        cuda_assert(cudaPeekAtLastError());

        cuda_assert(cudaDeviceSynchronize());

        cuda_assert(cudaDestroySurfaceObject(surface));

        cuda_assert(cudaGraphicsUnmapResources(1, &cudaTexture));

        cuda_assert(cudaDeviceSynchronize());

        glm::mat4 view(1.f);
        view = glm::translate(view, glm::vec3(
            camera.xOffset / width,
            camera.yOffset / height,
            0.f
        ));
        view = glm::scale(view, glm::vec3(camera.getScale(), camera.getScale(), 1.f));

        glm::mat4 model(1.f);
        model = glm::translate(model, glm::vec3(
            CELL_SIZE * minX / width,
            CELL_SIZE * minY / height,
            0.f
        ));
        model = glm::scale(model, glm::vec3(CELL_SIZE * texWidth / width, CELL_SIZE * texHeight / height, 1.f));

        arrows.use();
        arrows.view.set(1, false, glm::value_ptr(view));
        arrows.model.set(1, false, glm::value_ptr(model));
        glBindVertexArray(VAO);
        glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, 0);

        grid.use();
        grid.view.set(1, false, glm::value_ptr(view));
        grid.model.set(1, false, glm::value_ptr(model));
        grid.tileCount.set(texWidth, texHeight);
        glBindVertexArray(VAO);
        glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, 0);

        glfwSwapBuffers(window);
    }

    glDeleteVertexArrays(1, &VAO);
    glDeleteBuffers(1, &VBO);

    glfwDestroyWindow(window);
    glfwTerminate();

    return 0;
}