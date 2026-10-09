//
// Instruction set definition.
//

const std = @import("std");
const testing = std.testing;

// Instruction enum.
// To keep things easy and aligned with original Tierra implementation,
// Instructions are u8, even though they could be u5.
// This simplifies mutation later on.
pub const Instruction = enum(u8) {
    nop_0, // No operation
    nop_1, // No operation
    or1, // Flip low order bit of cx, cx ^= 1
    shl, // Shift cx register left, cx <<= 1
    zero, // Set cx register to zero, cx = 0
    if_cz, // If cx == 0, execute next instruction
    sub_ab, // Subtraction, cx = ax - bx
    sub_ac, // Subtraction, ax = ax - cx
    inc_a, // Increment ax, ax++
    inc_b, // Increment bx, bx++
    dec_c, // Decrement cx, cx--
    inc_c, // Increment cx, cx++
    push_ax, // Push ax on stack
    push_bx, // Push bx on stack
    push_cx, // Push cx on stack
    push_dx, // Push dx on stack
    pop_ax, // Pop top of stack into ax
    pop_bx, // Pop top of stack into bx
    pop_cx, // Pop top of stack into cx
    pop_dx, // Pop top of stack into dx
    jmp, // Move IP forward to template
    jmpb, // Move IP backward to template
    call, // Call a procedure
    ret, // Return from procedure
    mov_cd, // Move cx to dx, dx = cx
    mov_ab, // Move ax to bx, bx = ax
    mov_iab, // Move instruction at address in bx to address in ax
    adr, // Address of nearest template to ax
    adrb, // Search backward for template
    adrf, // Search forward for template
    mal, // Allocate memory for daughter cell
    divide, // Cell division
};

pub fn is_nop(value: Instruction) bool {
    return (value == Instruction.nop_0) or (value == Instruction.nop_1);
}

pub fn complement(value: Instruction) Instruction {
    return switch (value) {
        Instruction.nop_0 => Instruction.nop_1,
        Instruction.nop_1 => Instruction.nop_0,
        else => value,
    };
}

test "is nop" {
    try testing.expect(is_nop(Instruction.nop_0));
    try testing.expect(is_nop(Instruction.nop_1));
    try testing.expect(!is_nop(Instruction.adr));
}
