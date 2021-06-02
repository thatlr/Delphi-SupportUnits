# Delphi-SupportUnits
Various units to deal with memory allocation and general issues


General note:
I do believe that someone could benefit from the publication of this helper units, but if you have other or better solutions, or don't see
the issues addressed here, please continue to go your own way.


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

It provides checks for Delphi and COM memory allocations (detection of double-free and of corruption by writing past the end of
allocated blocks).
For Delphi memory, it also detects memory leaks and reports them at program exit.

## WinMemMgr

Simple replacement for the built-in Delphi memory manager, by using the Windows Heap.

(I care for thread-safety and low fragmentation, but not so much for ultimate performance. As the Windows heap is used by most
Visual C/C++ programs through the standard malloc implementation, it should be fine for this requirements.)


## CorrectLocale

Workaround for a Windows 7 bug. Its usage is mandatory to force SysUtils.InitSysLocale to always get a correct value from
GetThreadLocale() when initializing its regional settings.


My programs include the following sequence of units in the respective .dpr files:

uses
  WinMemMgr,
  MemTest,
  CorrectLocale,
  ....
