if(NOT DEFINED OBJDUMP OR NOT DEFINED INPUT_FILE OR NOT DEFINED OUTPUT_FILE)
    message(FATAL_ERROR "OBJDUMP, INPUT_FILE and OUTPUT_FILE are required")
endif()

execute_process(
    COMMAND "${OBJDUMP}" -d -S "${INPUT_FILE}"
    OUTPUT_FILE "${OUTPUT_FILE}"
    ERROR_VARIABLE objdump_error
    RESULT_VARIABLE objdump_result
)

if(NOT objdump_result EQUAL 0)
    message(FATAL_ERROR "objdump failed: ${objdump_error}")
endif()
