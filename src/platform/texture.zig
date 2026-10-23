//! Images on the GPU, for ImGui to draw: RGBA, 8 bits per channel.

const std = @import("std");
const c = @import("c");
const sdl = @import("sdl.zig");

pub const Error = sdl.Error;
const fail = sdl.fail;

pub const Pixel = [4]u8;
const pixel_bytes = @sizeOf(Pixel);

pub const Texture = struct {
    handle: *c.SDL_GPUTexture,
    width: u32,
    height: u32,

    /// Uploads `pixels` (`width` × `height`, row by row) into a new texture.
    pub fn upload(gpu: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const Pixel) Error!Texture {
        std.debug.assert(pixels.len == @as(usize, width) * height);
        const handle = c.SDL_CreateGPUTexture(gpu, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        }) orelse return fail("SDL_CreateGPUTexture");
        errdefer c.SDL_ReleaseGPUTexture(gpu, handle);
        var texture: Texture = .{ .handle = handle, .width = width, .height = height };
        try texture.replace(gpu, pixels);
        return texture;
    }

    /// Replaces the texture's pixels with `pixels`, of the same size.
    pub fn replace(texture: *Texture, gpu: *c.SDL_GPUDevice, pixels: []const Pixel) Error!void {
        std.debug.assert(pixels.len == @as(usize, texture.width) * texture.height);
        const size: u32 = @intCast(pixels.len * pixel_bytes);
        const transfer = c.SDL_CreateGPUTransferBuffer(gpu, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = size }) orelse return fail("SDL_CreateGPUTransferBuffer");
        defer c.SDL_ReleaseGPUTransferBuffer(gpu, transfer);
        const mapped = c.SDL_MapGPUTransferBuffer(gpu, transfer, false) orelse return fail("SDL_MapGPUTransferBuffer");
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..size], std.mem.sliceAsBytes(pixels));
        c.SDL_UnmapGPUTransferBuffer(gpu, transfer);

        const commands = c.SDL_AcquireGPUCommandBuffer(gpu) orelse return fail("SDL_AcquireGPUCommandBuffer");
        const copy = c.SDL_BeginGPUCopyPass(commands);
        c.SDL_UploadToGPUTexture(copy, &.{ .transfer_buffer = transfer, .offset = 0 }, &.{
            .texture = texture.handle,
            .w = texture.width,
            .h = texture.height,
            .d = 1,
        }, false);
        c.SDL_EndGPUCopyPass(copy);
        if (!c.SDL_SubmitGPUCommandBuffer(commands)) return fail("SDL_SubmitGPUCommandBuffer");
    }

    pub fn release(texture: *Texture, gpu: *c.SDL_GPUDevice) void {
        c.SDL_ReleaseGPUTexture(gpu, texture.handle);
        texture.* = undefined;
    }

    /// Returns the texture the way ImGui refers to it.
    pub fn ref(texture: Texture) c.ImTextureRef {
        return .{ ._TexData = null, ._TexID = @intFromPtr(texture.handle) };
    }
};
