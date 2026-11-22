// Isolated Epson V600 RGB/IR acquisition. The app keeps using SANE for previews
// and ordinary scans. This process loads the user's installed Epson library.
#include "epson_command.hpp"
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr unsigned vendor = 0x04b8, product = 0x013a;
constexpr int transparent = 3, rgb_type = 1, ir_type = 2;
constexpr size_t max_bytes = 512u * 1024u * 1024u;

std::string text(const std::filesystem::path& path) {
    std::ifstream file(path);
    std::string value;
    std::getline(file, value);
    return value;
}
unsigned number(const std::string& s, int base = 10) {
    if (s.empty() || s[0] == '-') throw std::runtime_error("invalid number");
    size_t end = 0;
    auto n = std::stoul(s, &end, base);
    if (end != s.size() || n > std::numeric_limits<unsigned>::max())
        throw std::runtime_error("invalid number");
    return static_cast<unsigned>(n);
}
// Match the SANE USB address to a serial number, rather than opening a second
// attached V600 by accident. Ambiguous devices without a serial are refused.
std::string serial_for(const std::string& device) {
    const auto last = device.rfind(':');
    const auto previous = last == std::string::npos ? last : device.rfind(':', last - 1);
    if (previous == std::string::npos) throw std::runtime_error("invalid SANE USB address");
    unsigned bus = number(device.substr(previous + 1, last - previous - 1));
    unsigned address = number(device.substr(last + 1));
    std::string serial;
    unsigned count = 0;
    bool found = false;
    for (const auto& entry : std::filesystem::directory_iterator("/sys/bus/usb/devices")) {
        const auto path = entry.path();
        if (text(path / "idVendor") != "04b8" || text(path / "idProduct") != "013a") continue;
        ++count;
        if (number(text(path / "busnum")) == bus && number(text(path / "devnum")) == address) {
            serial = text(path / "serial");
            found = true;
        }
    }
    if (!found || (count > 1 && serial.empty())) throw std::runtime_error("V600 USB address is missing or ambiguous");
    // Epson serials are plain ASCII. Reject JSON metacharacters before encoding.
    if (serial.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_") != std::string::npos)
        throw std::runtime_error("unsupported USB serial number");
    return serial;
}
struct Result final : epson::Result {
    std::string string;
    bool set(const char* p) override { try { string = p; return true; } catch (...) { return false; } }
    const char* get() override { return string.c_str(); }
};
void check(int code, const char* action) {
    if (code) throw std::runtime_error(std::string(action) + ": Epson error " + std::to_string(code));
}
void set(epson::Scanner* scanner, const char* key, const std::string& value) {
    auto json = std::string("{\"") + key + "\":" + value + "}";
    check(scanner->set_all(json.c_str()), key);
}
void integer(epson::Scanner* scanner, const char* key, unsigned value) {
    set(scanner, key, "{\"int\":" + std::to_string(value) + "}");
    Result result;
    check(scanner->value(key, &result), key);
    auto colon = result.string.find(':', result.string.find("\"int\""));
    if (colon == std::string::npos || std::strtoul(result.string.c_str() + colon + 1, nullptr, 10) != value)
        throw std::runtime_error(std::string(key) + ": scanner changed the requested value");
}
struct Capture final : epson::Delegate, epson::ImageDelegate {
    std::string folder;
    unsigned expected_width, expected_height, requested_depth;
    std::vector<uint8_t> bytes;
    bool rgb = false, infrared = false, failed = false;
    Capture(std::string dir, unsigned w, unsigned h, unsigned depth)
        : folder(std::move(dir)), expected_width(w), expected_height(h), requested_depth(depth) {}
    void progress(epson::Image* image) {
        // Replacing a tiny file avoids a pipe filling while a driver blocks.
        auto path = folder + "/progress";
        if (auto* file = std::fopen(path.c_str(), "w")) {
            unsigned stride = std::max(image->stride(), 1);
            unsigned lines = static_cast<unsigned>(bytes.size() / stride);
            if (image->ice_type() == ir_type) lines += expected_height;
            std::fprintf(file, "%u %u\n", lines, expected_height * 2);
            std::fclose(file);
        }
    }
    void image_begin(epson::Scanner*, epson::Image* image) override {
        bytes.clear();
        if (image->delegate(this)) { failed = true; image->abort(); return; }
        progress(image);
    }
    void received(epson::Image* image, epson::Buffer* buffer) override {
        const auto n = buffer->length();
        if (failed || n > max_bytes || bytes.size() > max_bytes - n) {
            failed = true; image->abort(); return;
        }
        try {
            if (n) bytes.insert(bytes.end(), buffer->data(), buffer->data() + n);
            progress(image);
        } catch (...) { failed = true; image->abort(); }
    }
    void image_end(epson::Scanner*, epson::Image* image) override {
        try {
            const int type = image->ice_type(), w = image->width(), h = image->height();
            const int channels = image->channels(), depth = image->depth(), stride = image->stride();
            const bool colour = type == rgb_type;
            if (failed || w != static_cast<int>(expected_width) || h != static_cast<int>(expected_height) ||
                !((colour && channels == 3 && depth == static_cast<int>(requested_depth)) ||
                  (type == ir_type && channels == 1 && depth == 8)))
                throw std::runtime_error("unexpected image dimensions, type or depth");
            const size_t row = size_t(w) * channels * (depth / 8);
            if (stride < 0 || size_t(stride) < row || bytes.size() != size_t(stride) * h)
                throw std::runtime_error("incomplete image payload");
            auto path = folder + (colour ? "/rgb.ppm" : "/infrared.pgm");
            auto* file = std::fopen(path.c_str(), "wbx");
            if (!file) throw std::runtime_error("cannot create output image");
            std::fprintf(file, "%s\n%d %d\n%d\n", colour ? "P6" : "P5", w, h, depth == 16 ? 65535 : 255);
            bool written = true;
            for (int y = 0; y < h; ++y) {
                auto* start = bytes.data() + size_t(y) * stride;
                // ESC/I USB words are little endian; PNM words are big endian.
                if (depth == 16) for (size_t i = 0; i < row; i += 2) std::swap(start[i], start[i + 1]);
                if (std::fwrite(start, 1, row, file) != row) { written = false; break; }
            }
            if (std::fclose(file)) written = false;
            if (!written) throw std::runtime_error("cannot finish output image");
            if (colour) rgb = true; else infrared = true;
            std::cerr << (colour ? "RGB" : "IR") << ": " << w << 'x' << h << ", " << depth << " bits\n";
        } catch (const std::exception& e) { std::cerr << e.what() << '\n'; failed = true; }
    }
    void begin(epson::Image*) override {}
    void end(epson::Image*) override {}
    void aborted(epson::Image*) override { failed = true; }
    void continuous_begin(epson::Scanner*) override {}
    void continuous_end(epson::Scanner*) override {}
    void cancel_begin(epson::Scanner*) override {}
    void cancel_end(epson::Scanner*) override { failed = true; }
    void complete(epson::Scanner*, int code) override { if (code) { failed = true; std::cerr << "Epson scan error " << code << '\n'; } }
    void interrupted(epson::Scanner*, int) override { failed = true; }
    void communication_error(epson::Scanner*, int) override { failed = true; }
    void warmup_begin(epson::Scanner*) override {}
    void warmup_end(epson::Scanner*) override {}
    void network_start(epson::Scanner*) override {}
    void network_stop(epson::Scanner*) override {}
    void disconnected(epson::Scanner*) override { failed = true; }
    void server_error(epson::Scanner*) override { failed = true; }
    int prevent_timeout(epson::Scanner*) override { return false; }
    void timeout(epson::Scanner*) override { failed = true; }
    void reserved(epson::Scanner*, const char*) override { failed = true; }
    void button(uint8_t) override {}
    void request_stop(epson::Scanner*) override {}
    void request_connection(epson::Scanner*) override {}
    void status_changed(epson::Scanner*) override {}
};
} // namespace

int main(int argc, char** argv) {
    epson::Scanner* scanner = nullptr;
    void* library = nullptr;
    int status = 1;
    try {
        // All area arguments are integer pixels, with a checked square resolution.
        if (argc != 12 || std::strcmp(argv[1], "--scan")) {
            std::cerr << "Usage: minilab-epson-ir --scan library device folder dpi depth film x y width height\n";
            return 2;
        }
        unsigned dpi = number(argv[5]), depth = number(argv[6]), film = number(argv[7]);
        unsigned x = number(argv[8]), y = number(argv[9]), w = number(argv[10]), h = number(argv[11]);
        if (!(dpi == 800 || dpi == 1600 || dpi == 3200) || !(depth == 8 || depth == 16) || film > 1 ||
            !w || !h || size_t(w) * h > max_bytes / 6 ||
            double(x) + w > 2.7 * dpi || double(y) + h > 10.0 * dpi)
            throw std::runtime_error("unsupported IR request");
        const auto serial = serial_for(argv[3]);
        library = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
        if (!library) throw std::runtime_error(dlerror());
        auto create = reinterpret_cast<epson::Create>(dlsym(library, "ESCreateScanner"));
        if (!create) throw std::runtime_error("Epson command interface is missing");
        check(create(0, &scanner), "create scanner");
        if (!scanner) throw std::runtime_error("Epson returned no scanner");
        Capture capture(argv[4], w, h, depth);
        scanner->delegate(&capture);
        auto connection = std::string("{\"ConnectionSetting\":[{\"ConnectType\":{\"int\":3},\"VID\":{\"int\":") +
            std::to_string(vendor) + "},\"PID\":{\"int\":" + std::to_string(product) +
            "},\"InterpreterName\":{\"string\":\"es2intif\"},\"SERIAL_NUMBER\":{\"string\":\"" + serial + "\"}}]}";
        check(scanner->connection(connection.c_str()), "connection");
        check(scanner->open(), "open scanner");
        // A trailing slash avoids Epson 6.7.70's GetTempFileName allocation bug.
        set(scanner, "workFolder", "{\"string\":\"/tmp/\"}");
        integer(scanner, "functionalUnitType", transparent);
        integer(scanner, "xResolution", dpi);
        integer(scanner, "yResolution", dpi);
        integer(scanner, "colorFormat", depth == 16 ? 1808 : 1800);
        integer(scanner, "filmType", film);
        integer(scanner, "gammaMode", 3);
        set(scanner, "colorMatrix", "{\"array_f\":[]}");
        set(scanner, "scanAreaInPixel", "{\"rect_u\":{\"x\":" + std::to_string(x) +
            ",\"y\":" + std::to_string(y) + ",\"w\":" + std::to_string(w) + ",\"h\":" + std::to_string(h) + "}}");
        integer(scanner, "digitalICE", 1);
        check(scanner->scan(), "RGB/IR scan");
        if (capture.failed || !capture.rgb || !capture.infrared) throw std::runtime_error("RGB/IR acquisition is incomplete");
        status = 0;
        scanner->delegate(nullptr);
    } catch (const std::exception& e) {
        std::cerr << "Epson IR: " << e.what() << '\n';
        if (scanner) scanner->delegate(nullptr);
    }
    if (scanner) { if (scanner->opened()) scanner->close(); scanner->destroy(); }
    if (library) dlclose(library);
    return status;
}
