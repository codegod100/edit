#!/usr/bin/env bash
set -euo pipefail

echo "--- Scaffolding/Resetting complex_c ---"
mkdir -p examples/complex_c
printf '#include <stdio.h>
// Missing stdlib.h for malloc/free

typedef struct {
    int x;
    int y;
} Point;

void print_point(Point* p) {
    // Syntax error: missing semicolon
    printf("Point(%%d, %%d)
", p->x, p->y)
}

int main() {
    // Logical error: Uninitialized pointer dereference if not allocated,
    // but here we just try to use malloc without include.
    Point* p = (Point*)malloc(sizeof(Point));
    p->x = 10;
    p->y = 20;
    
    print_point(p);
    
    // Memory leak: free(p) missing
    free(p);
    
    // Typo in return
    retrun 0;
}
' > examples/complex_c/broken.c
