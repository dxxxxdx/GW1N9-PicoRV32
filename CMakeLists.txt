cmake_minimum_required(VERSION 3.20)

# Use a local bare-metal RISC-V toolchain when present, otherwise search PATH.
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR riscv32)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(RISCV_TOOLCHAIN_BIN
    "${CMAKE_CURRENT_SOURCE_DIR}/hostutil/bin"
    CACHE PATH "Directory containing the RISC-V cross compiler")
set(RISCV_TOOLCHAIN_TRIPLE
    "riscv32-dxxdx-elf"
    CACHE STRING "RISC-V bare-metal compiler target triple")

set(LOCAL_RISCV_GCC
    "${RISCV_TOOLCHAIN_BIN}/${RISCV_TOOLCHAIN_TRIPLE}-gcc")

if(EXISTS "${LOCAL_RISCV_GCC}")
    set(RISCV_GCC "${LOCAL_RISCV_GCC}")
else()
    find_program(RISCV_GCC
        NAMES
            "${RISCV_TOOLCHAIN_TRIPLE}-gcc"
            riscv32-unknown-elf-gcc
        DOC "RISC-V bare-metal GCC")
endif()

if(NOT RISCV_GCC)
    message(FATAL_ERROR
        "RISC-V GCC was not found. Set RISCV_TOOLCHAIN_BIN and "
        "RISCV_TOOLCHAIN_TRIPLE, or add the toolchain to PATH.")
endif()

get_filename_component(TOOLCHAIN_BIN "${RISCV_GCC}" DIRECTORY)
get_filename_component(RISCV_GCC_NAME "${RISCV_GCC}" NAME)
string(REGEX REPLACE "gcc$" "" TOOLCHAIN_BASENAME "${RISCV_GCC_NAME}")
set(TOOLCHAIN_PREFIX "${TOOLCHAIN_BIN}/${TOOLCHAIN_BASENAME}")

set(CMAKE_C_COMPILER "${TOOLCHAIN_PREFIX}gcc")
set(CMAKE_ASM_COMPILER "${TOOLCHAIN_PREFIX}gcc")
set(CMAKE_AR "${TOOLCHAIN_PREFIX}ar")
set(CMAKE_RANLIB "${TOOLCHAIN_PREFIX}ranlib")

set(RISCV_OBJCOPY "${TOOLCHAIN_PREFIX}objcopy")
set(RISCV_OBJDUMP "${TOOLCHAIN_PREFIX}objdump")
set(RISCV_SIZE "${TOOLCHAIN_PREFIX}size")

foreach(tool IN ITEMS
        CMAKE_C_COMPILER CMAKE_AR CMAKE_RANLIB
        RISCV_OBJCOPY RISCV_OBJDUMP RISCV_SIZE)
    if(NOT EXISTS "${${tool}}")
        message(FATAL_ERROR "Required RISC-V tool not found: ${${tool}}")
    endif()
endforeach()

project(gw1nr9_rv32_firmware LANGUAGES C ASM)

set(LINKER_SCRIPT
    "${CMAKE_CURRENT_SOURCE_DIR}/hostutil/dxxdx_start_ld/dxxdxLink.ld")
set(FIRMWARE_MAP "${CMAKE_CURRENT_BINARY_DIR}/helloworld.map")
set(FIRMWARE_BIN "${CMAKE_CURRENT_BINARY_DIR}/helloworld.bin")
set(FIRMWARE_ASM "${CMAKE_CURRENT_BINARY_DIR}/helloworld.asm")

add_executable(firmware
    helloworld/main.c
    hostutil/include/UART.c
    hostutil/dxxdx_start_ld/start.S
)

set_target_properties(firmware PROPERTIES
    OUTPUT_NAME "helloworld"
    SUFFIX ".elf"
)

target_include_directories(firmware PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/hostutil/include"
)

target_compile_options(firmware PRIVATE
    -march=rv32i
    -mabi=ilp32
    -Os
    -ffreestanding
    -fno-pic
    -fno-pie
    -ffunction-sections
    -fdata-sections
    $<$<COMPILE_LANGUAGE:C>:-std=c11>
    $<$<COMPILE_LANGUAGE:C>:-fno-builtin>
    $<$<COMPILE_LANGUAGE:C>:-fno-common>
    $<$<COMPILE_LANGUAGE:C>:-fno-stack-protector>
    $<$<COMPILE_LANGUAGE:C>:-fno-unwind-tables>
    $<$<COMPILE_LANGUAGE:C>:-fno-asynchronous-unwind-tables>
    $<$<COMPILE_LANGUAGE:C>:-Wall>
    $<$<COMPILE_LANGUAGE:C>:-Wextra>
)

target_link_options(firmware PRIVATE
    -march=rv32i
    -mabi=ilp32
    -nostdlib
    -nostartfiles
    -static
    -no-pie
    "-T${LINKER_SCRIPT}"
    -Wl,--gc-sections
    -Wl,--build-id=none
    "-Wl,-Map=${FIRMWARE_MAP}"
)

# Compiler-generated RV32I helpers such as software multiply/divide live here.
target_link_libraries(firmware PRIVATE gcc)

# Changing the linker script must trigger a relink.
set_property(TARGET firmware APPEND PROPERTY LINK_DEPENDS "${LINKER_SCRIPT}")

add_custom_command(TARGET firmware POST_BUILD
    COMMAND "${RISCV_OBJCOPY}" -O binary
            "$<TARGET_FILE:firmware>" "${FIRMWARE_BIN}"
    COMMAND "${CMAKE_COMMAND}"
            "-DOBJDUMP=${RISCV_OBJDUMP}"
            "-DINPUT_FILE=$<TARGET_FILE:firmware>"
            "-DOUTPUT_FILE=${FIRMWARE_ASM}"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/objdump.cmake"
    COMMAND "${RISCV_SIZE}" "$<TARGET_FILE:firmware>"
    BYPRODUCTS "${FIRMWARE_BIN}" "${FIRMWARE_ASM}"
    COMMENT "Generating helloworld.bin and helloworld.asm"
    VERBATIM
)

add_custom_target(asm DEPENDS firmware)
