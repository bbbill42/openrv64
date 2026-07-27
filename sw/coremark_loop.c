/*
 * Branch-heavy, finite workload derived from EEMBC CoreMark's
 * core_state.c state machine.
 *
 * Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)
 * Original author: Shay Gal-on
 * SPDX-License-Identifier: Apache-2.0
 *
 * This is intentionally not a CoreMark benchmark and produces no score.  It
 * keeps the useful switch/if parser and uses a fixed input corpus as a small
 * bare-metal processor workload.
 */

#include <stdint.h>

enum core_state {
    CORE_START = 0,
    CORE_INVALID,
    CORE_S1,
    CORE_S2,
    CORE_INT,
    CORE_FLOAT,
    CORE_EXPONENT,
    CORE_SCIENTIFIC,
    NUM_CORE_STATES
};

/*
 * Volatile preserves the data-dependent loads and branches even though the
 * corpus is pre-baked.  The characters cover every state and several invalid
 * exits.  Repetition gives the predictor a stable but nontrivial pattern.
 */
static const volatile uint8_t state_input[] =
    "5012,1234,-874,+122,"
    "35.54400,.1234500,-110.700,+0.64400,"
    "5.500e+3,-.123e-2,-87e+832,+0.6e-12,"
    "T0.3e-1F,-T.T++Tq,1T3.4e4z,34.0e-T^,"
    "+17,-0,.0,99.99,6.02e+23,-1e-9,bad-token,"
    "5012,1234,-874,+122,"
    "35.54400,.1234500,-110.700,+0.64400,"
    "5.500e+3,-.123e-2,-87e+832,+0.6e-12,"
    "T0.3e-1F,-T.T++Tq,1T3.4e4z,34.0e-T^,"
    "+17,-0,.0,99.99,6.02e+23,-1e-9,bad-token,";

/* A debugger-visible side effect prevents dead-code elimination. */
volatile uint32_t coremark_loop_sink = UINT32_C(0x6d5a56a9);

enum {
    COREMARK_LOOP_PASSES = 8
};

static uint8_t
is_digit(uint8_t value)
{
    return (uint8_t)(((value >= (uint8_t)'0') &
                      (value <= (uint8_t)'9')) != 0u);
}

/* Adapted directly from CoreMark's core_state_transition(). */
static __attribute__((noinline)) enum core_state
state_transition(const volatile uint8_t **input,
                 uint32_t *restrict transition_count)
{
    // The parser input and transition counters are disjoint.  Stating that
    // contract lets GCC place the next volatile byte load and pointer update
    // between a counter load and its dependent increment/store.
    const volatile uint8_t *restrict cursor = *input;
    enum core_state state = CORE_START;

    for (; (*cursor != 0u) && (state != CORE_INVALID); cursor++) {
        uint8_t symbol = *cursor;

        if (symbol == (uint8_t)',') {
            cursor++;
            break;
        }

        switch (state) {
        case CORE_START:
            if (is_digit(symbol) != 0u) {
                state = CORE_INT;
            } else if ((symbol == (uint8_t)'+') ||
                       (symbol == (uint8_t)'-')) {
                state = CORE_S1;
            } else if (symbol == (uint8_t)'.') {
                state = CORE_FLOAT;
            } else {
                state = CORE_INVALID;
                transition_count[CORE_INVALID]++;
            }
            transition_count[CORE_START]++;
            break;

        case CORE_S1:
            if (is_digit(symbol) != 0u) {
                state = CORE_INT;
            } else if (symbol == (uint8_t)'.') {
                state = CORE_FLOAT;
            } else {
                state = CORE_INVALID;
            }
            transition_count[CORE_S1]++;
            break;

        case CORE_INT:
            if (symbol == (uint8_t)'.') {
                state = CORE_FLOAT;
                transition_count[CORE_INT]++;
            } else if (is_digit(symbol) == 0u) {
                state = CORE_INVALID;
                transition_count[CORE_INT]++;
            }
            break;

        case CORE_FLOAT:
            if ((symbol == (uint8_t)'E') ||
                (symbol == (uint8_t)'e')) {
                state = CORE_S2;
                transition_count[CORE_FLOAT]++;
            } else if (is_digit(symbol) == 0u) {
                state = CORE_INVALID;
                transition_count[CORE_FLOAT]++;
            }
            break;

        case CORE_S2:
            if ((symbol == (uint8_t)'+') ||
                (symbol == (uint8_t)'-')) {
                state = CORE_EXPONENT;
            } else {
                state = CORE_INVALID;
            }
            transition_count[CORE_S2]++;
            break;

        case CORE_EXPONENT:
            if (is_digit(symbol) != 0u) {
                state = CORE_SCIENTIFIC;
            } else {
                state = CORE_INVALID;
            }
            transition_count[CORE_EXPONENT]++;
            break;

        case CORE_SCIENTIFIC:
            if (is_digit(symbol) == 0u) {
                state = CORE_INVALID;
                transition_count[CORE_INVALID]++;
            }
            break;

        default:
            break;
        }
    }

    *input = cursor;
    return state;
}

static __attribute__((noinline)) uint32_t
scan_input(void)
{
    uint32_t final_count[NUM_CORE_STATES];
    uint32_t transition_count[NUM_CORE_STATES];
    const volatile uint8_t *cursor = state_input;
    uint32_t mix = UINT32_C(0x811c9dc5);
    unsigned int state;

    for (state = 0; state < NUM_CORE_STATES; state++) {
        final_count[state] = 0;
        transition_count[state] = 0;
    }

    while (*cursor != 0u) {
        enum core_state end_state =
            state_transition(&cursor, transition_count);
        final_count[end_state]++;
    }

    /* Small integer tail: consume the counters without adding libc or M. */
    for (state = 0; state < NUM_CORE_STATES; state++) {
        mix ^= final_count[state] +
               (transition_count[state] << (state & 7u));
        mix = (mix << 5) | (mix >> 27);
        mix += UINT32_C(0x9e3779b9);
    }

    return mix;
}

uint32_t
coremark_loop_with_sink(volatile uint32_t *sink)
{
    uint32_t accumulator = *sink;
    unsigned int pass;

    for (pass = 0; pass < COREMARK_LOOP_PASSES; pass++) {
        accumulator ^= scan_input();
        accumulator = (accumulator << 7) | (accumulator >> 25);
        *sink = accumulator;
    }

    return accumulator;
}

void
coremark_loop(void)
{
    (void)coremark_loop_with_sink(&coremark_loop_sink);
}
