// The Linux binary interface used by Epson Scan 2's ESCreateScanner entry point.
// Only calls needed for acquisition are named. Reserved slots keep the interface's
// virtual method order. No driver, firmware or image-processing plug-in is included.
// Reference: Epson Scan 2 6.7.70, src/Include/ES2Command and IESBuffer.h.
#pragma once
#include <cstdint>

namespace epson {
struct Result {
    virtual ~Result() = default;
    virtual bool set(const char*) = 0;
    virtual const char* get() = 0;
};
struct Buffer {
    virtual ~Buffer() = default;
    virtual int type() = 0;
    virtual bool empty() = 0;
    virtual uint32_t length() const = 0;
    virtual uint8_t* data() const = 0;
};
struct Image;
struct ImageDelegate {
    virtual void begin(Image*) = 0;
    virtual void end(Image*) = 0;
    virtual void aborted(Image*) = 0;
    virtual void received(Image*, Buffer*) = 0;
};
struct Image {
    virtual void destroy() = 0;
    virtual void reserve1() = 0;
    virtual bool reserve2() = 0;
    virtual int delegate(ImageDelegate*) = 0;
    virtual void reserve4() = 0;
    virtual void reserve5() = 0;
    virtual void reserve6() = 0;
    virtual void reserve7() = 0;
    virtual void abort() = 0;
    virtual void reserve9() = 0;
    virtual void reserve10() = 0;
    virtual void reserve11() = 0;
    virtual uint32_t reserve12() = 0;
    virtual uint32_t reserve13() = 0;
    virtual int reserve14() = 0;
    virtual int reserve15() = 0;
    virtual bool reserve16() = 0;
    virtual int reserve17() = 0;
    virtual bool reserve18() = 0;
    virtual bool reserve19() = 0;
    virtual bool reserve20() = 0;
    virtual bool reserve21() = 0;
    virtual bool reserve22() = 0;
    virtual int format() = 0;
    virtual int ice_type() = 0;
    virtual int reserve26() = 0;
    virtual void reserve27() = 0;
    virtual void reserve28() = 0;
    virtual void reserve29() = 0;
    virtual int width() = 0;
    virtual int height() = 0;
    virtual int bits_per_pixel() = 0;
    virtual int channels() = 0;
    virtual int depth() = 0;
    virtual int stride() = 0;
};
struct Scanner;
struct Delegate {
    virtual void continuous_begin(Scanner*) = 0;
    virtual void continuous_end(Scanner*) = 0;
    virtual void image_begin(Scanner*, Image*) = 0;
    virtual void image_end(Scanner*, Image*) = 0;
    virtual void cancel_begin(Scanner*) = 0;
    virtual void cancel_end(Scanner*) = 0;
    virtual void complete(Scanner*, int) = 0;
    virtual void interrupted(Scanner*, int) = 0;
    virtual void communication_error(Scanner*, int) = 0;
    virtual void warmup_begin(Scanner*) = 0;
    virtual void warmup_end(Scanner*) = 0;
    virtual void network_start(Scanner*) = 0;
    virtual void network_stop(Scanner*) = 0;
    virtual void disconnected(Scanner*) = 0;
    virtual void server_error(Scanner*) = 0;
    virtual int prevent_timeout(Scanner*) = 0;
    virtual void timeout(Scanner*) = 0;
    virtual void reserved(Scanner*, const char*) = 0;
    virtual void button(uint8_t) = 0;
    virtual void request_stop(Scanner*) = 0;
    virtual void request_connection(Scanner*) = 0;
    virtual void status_changed(Scanner*) = 0;
};
struct Scanner {
    virtual void delegate(Delegate*) = 0;
    virtual int connection(const char*) = 0;
    virtual void destroy() = 0;
    virtual int open() = 0;
    virtual int close() = 0;
    virtual bool opened() const = 0;
    virtual int scan() = 0;
    virtual void reserve7() = 0;
    virtual int cancel() = 0;
    virtual int abort() = 0;
    virtual bool scanning() const = 0;
    virtual void reserve11() = 0;
    virtual void reserve12() = 0;
    virtual void reserve13() = 0;
    virtual void reserve14() = 0;
    virtual void reserve15() = 0;
    virtual void reserve16() = 0;
    virtual void reserve17() = 0;
    virtual void reserve18() = 0;
    virtual void reserve19() = 0;
    virtual void reserve20() = 0;
    virtual void reserve21() = 0;
    virtual void reserve22() = 0;
    virtual void reserve23() = 0;
    virtual int keys(Result*) = 0;
    virtual int default_value(const char*, Result*) = 0;
    virtual int value(const char*, Result*) = 0;
    virtual int set(const char*, const char*) = 0;
    virtual int set_all(const char*) = 0;
    virtual int values_for_key(const char*, Result*) = 0;
    virtual int values(Result*) = 0;
    virtual int available(const char*, Result*) = 0;
    virtual int all_available(Result*) = 0;
};
using Create = int (*)(int, Scanner**);
} // namespace epson
