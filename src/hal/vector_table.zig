//! ARM Cortex-M0+ Vector Table for RP2040

extern var _stack_top: anyopaque;

/// Default handler: infinite loop with breakpoint
fn defaultHandler() callconv(.c) void {
    while (true) {
        asm volatile ("bkpt #0");
    }
}

/// RP2040 IRQ numbers (RP2040 Datasheet §2.3.2)
pub const Irq = enum(u5) {
    TIMER_IRQ_0    = 0,
    TIMER_IRQ_1    = 1,
    TIMER_IRQ_2    = 2,
    TIMER_IRQ_3    = 3,
    PWM_IRQ_WRAP   = 4,
    USBCTRL_IRQ    = 5,
    XIP_IRQ        = 6,
    PIO0_IRQ_0     = 7,
    PIO0_IRQ_1     = 8,
    PIO1_IRQ_0     = 9,
    PIO1_IRQ_1     = 10,
    DMA_IRQ_0      = 11,
    DMA_IRQ_1      = 12,
    IO_IRQ_BANK0   = 13,
    IO_IRQ_QSPI    = 14,
    SIO_IRQ_PROC0  = 15,
    SIO_IRQ_PROC1  = 16,
    CLOCKS_IRQ     = 17,
    SPI0_IRQ       = 18,
    SPI1_IRQ       = 19,
    UART0_IRQ      = 20,
    UART1_IRQ      = 21,
    ADC_IRQ_FIFO   = 22,
    I2C0_IRQ       = 23,
    I2C1_IRQ       = 24,
    RTC_IRQ        = 25,
};

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
    /// IRQ handlers indexed by Irq enum (26 entries: IRQ0-IRQ25)
    irq: [26]*const fn () callconv(.c) void = .{&defaultHandler} ** 26,
};

/// Create the vector table instance with the given reset handler
pub fn vectorTable(reset_handler: *const fn () callconv(.naked) noreturn) VectorTable {
    return .{
        .initial_sp = @ptrCast(&_stack_top),
        .reset = reset_handler,
    };
}
