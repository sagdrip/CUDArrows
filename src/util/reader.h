#pragma once
#include <string>
#include <inttypes.h>

namespace util {
    class Reader {
    private:
        const std::string &buffer;
        unsigned int offset = 0;

    public:
        Reader(const std::string &buffer) : buffer(buffer) {}

        uint8_t readU8();

        uint16_t readU16();

        int16_t readI16();
    };
};