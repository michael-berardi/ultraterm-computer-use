package main

import (
	"encoding/json"
	"math"
	"strconv"
	"testing"
)

func TestPositiveIntegerRejectsFloatOverflow(t *testing.T) {
	limit := math.Ldexp(1, strconv.IntSize-1)
	for _, value := range []float64{limit, math.MaxFloat64, math.Inf(1), math.NaN(), 1.5, 0, -1} {
		if got, err := positiveIntFromValue(value, "max_tree_nodes"); err == nil {
			t.Errorf("accepted %v as %v", value, *got)
		}
	}
	valid := math.Floor(math.Nextafter(limit, 0))
	if got, err := positiveIntFromValue(valid, "max_tree_nodes"); err != nil || *got <= 0 {
		t.Errorf("rejected representable positive integer %v: %v", valid, err)
	}
}

func TestElementIndexRejectsFloatOverflow(t *testing.T) {
	for _, value := range []any{math.Ldexp(1, 63), -math.Ldexp(1, 64), math.MaxFloat64, json.Number("9223372036854775808"), json.Number("1e100")} {
		if got := elementIndexString(value); got != "" {
			t.Errorf("accepted out-of-range index %v as %q", value, got)
		}
	}
	for _, value := range []float64{0, 1, -1, -math.Ldexp(1, 63), math.Nextafter(math.Ldexp(1, 63), 0)} {
		if got := elementIndexString(value); got == "" {
			t.Errorf("rejected representable index %v", value)
		}
	}
}
