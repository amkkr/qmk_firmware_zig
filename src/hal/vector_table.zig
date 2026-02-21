//! ARM Cortex-M0+ Vector Table for RP2040

extern var _stack_top: anyopaque;

/// Default handler: infinite loop with breakpoint
fn defaultHandler() callconv(.c) void {
    while (true) {
        asm volatile ("bkpt #0");
    }
}

/// Cortex-M0+ vector table layout
pub const VectorTable = extern struct {
    initial_sp: *anyopaque,
    reset: *const fn () callconv(.naked) noreturn,
    nmi: *const fn () callconv(.c) void = &defaultHandler,
    hard_fault: *const fn () callconv(.c) void = &defaultHandler,
    reserved1: [7]u32 = .{0} ** 7,
    svcall: *const fn () callconv(.c) void = &defaultHandler,
    reserved2: [2]u32 = .{0} ** 2,
    pendsv: *const fn () callconv(.c) void = &defaultHandler,
    systick: *const fn () callconv(.c) void = &defaultHandler,
    irq: [26]*const fn () callconv(.c) void = .{&defaultHandler} ** 26,
};

/// Create the vector table instance
pub fn vectorTable(reset_handler: *const fn () callconv(.naked) noreturn) VectorTable {
    return .{
        .initial_sp = @ptrCast(&_stack_top),
        .reset = reset_handler,
    };
}
