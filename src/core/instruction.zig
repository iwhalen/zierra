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

// Masks first three bits before conversion to enum.
pub fn decode(value: u8) Instruction {
    const mask = 0x1f;
    return @enumFromInt(mask & value);
}

pub fn encode(instruction: Instruction) u8 {
    return @intFromEnum(instruction);
}

test "Sanity check decoding" {
    const nop_0_as_int = 0x00;
    const nop_0_decoded = decode(nop_0_as_int);
    try testing.expectEqual(Instruction.nop_0, nop_0_decoded);

    const divide_as_int = 0x1f;
    const divide_decoded = decode(divide_as_int);
    try testing.expectEqual(Instruction.divide, divide_decoded);

    const inc_b_as_int = 0x09;
    const inc_b_result = decode(inc_b_as_int);
    try testing.expectEqual(Instruction.inc_b, inc_b_result);
}

test "Decoding masks leading 3 bits" {
    const nop_0_with_leading = 0x20;
    const nop_0_decoded = decode(nop_0_with_leading);
    try testing.expectEqual(Instruction.nop_0, nop_0_decoded);

    const divide_with_leading = 0xff;
    const divide_decoded = decode(divide_with_leading);
    try testing.expectEqual(Instruction.divide, divide_decoded);
}

test "Sanity check encoding" {
    const nop_0_encoded = encode(Instruction.nop_0);
    try testing.expectEqual(0x00, nop_0_encoded);

    const divide_encoded = encode(Instruction.divide);
    try testing.expectEqual(0x1f, divide_encoded);

    const inc_b_encoded = encode(Instruction.inc_b);
    try testing.expectEqual(0x09, inc_b_encoded);
}
