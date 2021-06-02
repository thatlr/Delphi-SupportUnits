# Delphi-MemorySupport
Various units to deal with memory allocation

## ReserveLow2GB

This can be used to test for inappropriate pointer usage, caused by casting a pointer to a (signed) 32bit integer. Such value
will be negative which could result in wrong arithmetics or comparisions.

Including this unit forces all newly allocated memory to appear above the 2 GB virtual address. This applies to:
  - newly allocated heap memory (GetMem, CoTaskMemAlloc, SysAllocString, malloc, ...),
  - stack segments of new threads,
  - data segments assigned to new memory mappings,
  - code segements of newly loaded DLLs.
This is not only affecting Delphi code, but *all* other parts of the process also (e.g. COM-allcated memory, memory allocated
by Windows components or by third-party DLLs).

This unit does not depend on a specific Delphi memory manager and is therefore compatible with everyone.

## MemTest

This unit can be integrated into programs to verify correct memory management. From the point of view of the program,
only the speed is adversely affected and more memory is used.

It provides checks for Delphi and COM memory allocations (detecting of double-free and of corruption by writing past the end of
the allocated block).
For Delphi memory, it also detects memory leaks.
