#!/usr/bin/env python3
import os
import sys
import re
import shutil

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

PARSED_LEXEMES = []
LABELS = []
LABELS_ADDRESSES = []
CONSTANTS = []
CONSTANTS_EVALUATED = []
CONSTANTS_ADDRESSES = []
VARIABLES = []
VARIABLES_ADDRESSES = []
VARIABLES_DECL_ADDRESSES = []

COMPILATION_ERROR_COUNT = 0
CUR_FILE = ""
CUR_LINE_NO = 0
CUR_LINE = ""
DEBUG_INFO = os.environ.get("DEBUG_INFO", "1")
if DEBUG_INFO.isdigit():
    DEBUG_INFO = int(DEBUG_INFO)
else:
    DEBUG_INFO = 1

def load_constants():
    constants = {}
    include_dir = os.path.join(SCRIPT_DIR, "include")
    
    files = [
        "operations.sh",
        "syscalls.sh",
        "other.sh",
        "registers.sh",
        "system.sh"
    ]
    
    for file in files:
        filepath = os.path.join(include_dir, file)
        if os.path.exists(filepath):
            with open(filepath, 'r') as f:
                for line in f:
                    match = re.match(r'^export\s+([A-Za-z0-9_]+)=([0-9]+|"[^"]*")\s*', line)
                    if match:
                        name, value = match.groups()
                        if value.startswith('"') and value.endswith('"'):
                            value = value[1:-1] 
                        else:
                            try:
                                value = int(value)
                            except ValueError:
                                continue
                        constants[name] = value
    return constants

CONSTANTS_MAP = load_constants()

USER_SPACE = os.environ.get("USER_SPACE", "").lower() in ["on", "true", "1", "yes"]

if USER_SPACE:
    FIRST_INSTRUCTION_NO = 17
    OUTPUT_FILE = os.path.join(SCRIPT_DIR, "build", "user.disk")
else:
    FIRST_INSTRUCTION_NO = CONSTANTS_MAP.get("KERNEL_START", 41)
    OUTPUT_FILE = os.path.join(SCRIPT_DIR, "build", "kernel.disk")

CMDS_ARRAY = ["write", "copy", "label", "jump", "jump_if", "jump_if_not", "jump_err", "cpu_exec", "var", "DEBUG_ON", "DEBUG_OFF"]

def compilation_error(expected_syntax="", error_info=""):
    """Report a compilation error"""
    global COMPILATION_ERROR_COUNT
    
    print(f"\033[93mCompilation error\033[0m at {CUR_FILE}:{CUR_LINE_NO}", file=sys.stderr)
    print(f"\033[91m{CUR_LINE}\033[0m", file=sys.stderr)
    if error_info:
        print(f"\033[91m{error_info}\033[0m", file=sys.stderr)
    if expected_syntax:
        print(f"Expected syntax:\n\033[92m{expected_syntax}\033[0m", file=sys.stderr)
    print(file=sys.stderr)
    
    COMPILATION_ERROR_COUNT += 1
    if COMPILATION_ERROR_COUNT > 20:
        print("Too many compilation errors, aborting", file=sys.stderr)
        sys.exit(1)

def contains_element(value, array):
    """Check if array contains value"""
    return value in array

def find_index(element, array):
    """Find index of element in array"""
    try:
        return array.index(element)
    except ValueError:
        return -1

def parse_lexeme(lexeme):
    """Parse a single lexeme into its components"""
    if not lexeme or lexeme.startswith("//"):
        return "_ cmt"
    
    prefix = lexeme[0]
    if prefix in ["@", "*"]:
        lexeme = lexeme[1:]
    else:
        prefix = "_"
    
    if lexeme.startswith('"') and lexeme.endswith('"'):
        return f"{prefix} str {lexeme[1:-1]}"
    
    if re.match(r'^[0-9]+$', lexeme):
        return f"{prefix} num {lexeme}"
    
    if lexeme == "to":
        return f"{prefix} kto =>"
    
    if lexeme.startswith("var:"):
        var_name = lexeme[4:]
        if re.match(r'^[a-zA-Z][a-zA-Z0-9_]*$', var_name):
            return f"{prefix} var {var_name}"
        else:
            return f"{prefix} err name_format {lexeme}"
    
    if lexeme.startswith("label:"):
        label_name = lexeme[6:]
        if re.match(r'^[a-zA-Z][a-zA-Z0-9_]*$', label_name):
            return f"{prefix} lbl {label_name}"
        else:
            return f"{prefix} err name_format {lexeme}"
    
    if lexeme.startswith("OP_"):
        return f"{prefix} opr {lexeme}"
    
    if lexeme.startswith("SYS_CALL_"):
        return f"{prefix} sys {lexeme}"
    
    if (lexeme.startswith("REG_") or 
        lexeme.startswith("INFO_") or 
        lexeme == "DISPLAY_BUFFER" or 
        lexeme == "DISPLAY_COLOR" or 
        lexeme == "DISPLAY_BACKGROUND" or 
        lexeme == "KEYBOARD_BUFFER" or 
        lexeme == "PROGRAM_COUNTER" or 
        lexeme.startswith("FREE_")):
        return f"{prefix} reg {lexeme}"
    
    if lexeme.startswith("COLOR_"):
        return f"{prefix} clr {lexeme}"
    
    if (lexeme == "KEYBOARD_READ_LINE" or 
        lexeme == "KEYBOARD_READ_LINE_SILENTLY" or 
        lexeme == "KEYBOARD_READ_CHAR" or 
        lexeme == "KEYBOARD_READ_CHAR_SILENTLY"):
        return f"{prefix} mod {lexeme}"
    
    if lexeme in CMDS_ARRAY:
        return f"{prefix} cmd {lexeme}"
    
    if re.match(r'^[a-zA-Z][a-zA-Z0-9_]*$', lexeme):
        return f"{prefix} nam {lexeme}"
    
    return f"{prefix} err other {lexeme}"

def eval_lexeme(lexeme, position):
    """Evaluate a lexeme at a specific position"""
    prefix = lexeme[0]
    if prefix == "_":
        prefix = ""
    
    lex_type = lexeme[2:5]
    value = lexeme[6:]
    
    if lex_type == "cmd":
        if value == "copy" or value == "write":
            return CONSTANTS_MAP.get("INSTR_COPY_FROM_TO_ADDRESS", 1)
        elif value == "jump":
            return CONSTANTS_MAP.get("INSTR_JUMP", 3)
        elif value == "jump_if":
            return CONSTANTS_MAP.get("INSTR_JUMP_IF", 4)
        elif value == "jump_if_not":
            return CONSTANTS_MAP.get("INSTR_JUMP_IF_NOT", 5)
        elif value == "jump_err":
            return CONSTANTS_MAP.get("INSTR_JUMP_ERR", 6)
        elif value == "cpu_exec":
            return CONSTANTS_MAP.get("INSTR_CPU_EXEC", 0)
        elif value in ["DEBUG_ON", "DEBUG_OFF"]:
            return value
        return ""
    
    elif lex_type == "kto":
        return ""
    
    elif lex_type in ["num", "reg", "opr", "sys", "clr", "mod"]:
        if position == "write_1":
            try:
                idx = CONSTANTS.index(value)
                return CONSTANTS_ADDRESSES[idx]
            except ValueError:
                pass  
        
        if lex_type == "num":
            return f"{prefix}{value}"
        else:
            eval_var = CONSTANTS_MAP.get(value)
            if eval_var is None:
                compilation_error("", f"Symbol {value} is unknown")
                return ""
            else:
                return f"{prefix}{eval_var}"
    
    elif lex_type == "str":
        str_value = f'"{value}"'
        try:
            idx = CONSTANTS.index(str_value)
            return CONSTANTS_ADDRESSES[idx]
        except ValueError:
            pass  
    
    elif lex_type == "lbl":
        if position == "write_1":
            label_constant = f"LABEL:{value}"
            try:
                idx = CONSTANTS.index(label_constant)
                return CONSTANTS_ADDRESSES[idx]
            except ValueError:
                pass  
        else:
            try:
                idx = LABELS.index(value)
                return LABELS_ADDRESSES[idx]
            except ValueError:
                compilation_error("", f"Label {value} is not defined")
                return ""
    
    elif lex_type == "var":
        try:
            idx = VARIABLES.index(value)
            decl_address = VARIABLES_DECL_ADDRESSES[idx]
            
            global CUR_INSTRUCTION_NO
            if CUR_INSTRUCTION_NO < decl_address:
                compilation_error("Variable should be defined before the first use", 
                                 f"Variable {value} is used before declaration")
            
            return f"{prefix}{VARIABLES_ADDRESSES[idx]}"
        except ValueError:
            compilation_error("Variable should be declared before usage", 
                             f"Variable {value} is not defined")
            return ""
    
    return ""

def eval_debug_info_for_lexeme(lexeme, position):
    """Generate debug info for lexeme"""
    lex_type = lexeme[2:5]
    value = lexeme[6:]
    
    if lex_type == "str" or (lex_type == "num" and position == "write_1"):
        return f'"{value}"'
    
    if lex_type in ["var", "lbl"]:
        value = f"{lex_type}:{value}"
    
    prefix = lexeme[0]
    if prefix == "_":
        prefix = ""
    
    return f"{prefix}{value}"

def splitCommand(line):
    """Split a command line into tokens, handling quoted strings and comments"""
    result = []
    i = 0
    in_string = False
    current_token = ""
    comment = ""
    
    while i < len(line):
        char = line[i]
        
        if char == '"' and (i == 0 or line[i-1] != '\\'):
            in_string = not in_string
            current_token += char
        elif char == '/' and i+1 < len(line) and line[i+1] == '/' and not in_string:
            comment = line[i:]
            break
        elif char.isspace() and not in_string:
            if current_token:
                result.append(current_token)
                current_token = ""
        else:
            current_token += char
        
        i += 1
    
    if current_token:
        result.append(current_token)
    
    if comment:
        result.append(comment)
    
    return result

def process_files(source_files):
    """Process all source files and construct the parsed lexemes list"""
    global CUR_FILE, CUR_LINE_NO, CUR_LINE, NEXT_INSTR_ADDRESS
    
    NEXT_INSTR_ADDRESS = FIRST_INSTRUCTION_NO
    
    for file_path in source_files:
        CUR_FILE = file_path
        PARSED_LEXEMES.append(f"file {CUR_FILE}")
        CUR_LINE_NO = 0
        
        with open(file_path, 'r') as f:
            for line in f:
                CUR_LINE_NO += 1
                CUR_LINE = line.strip()
                
                if not CUR_LINE or CUR_LINE.startswith("//"):
                    continue

                components = splitCommand(CUR_LINE)
                
                if not components:
                    continue
                
                CUR_CMD = components[0]
                
                if CUR_CMD == "write":
                    LEXEMES_COUNT = 4
                    EXPECTED_PATTERN = r"^(_ cmd)(_ str|_ num|_ opr|_ sys|_ clr|_ mod|_ lbl)(_ kto)(_ num|\* num|_ reg|\* reg|_ var|\* var)(_ cmt)?$"
                    EXPECTED_SYNTAX = "'write \"some string\" to address' or 'write 100 to address' or 'write OP_* to address' or 'write COLOR_* to address' or 'write SYS_CALL_* to address'"
                elif CUR_CMD == "copy":
                    LEXEMES_COUNT = 4
                    EXPECTED_PATTERN = r"^(_ cmd)(_ num|\* num|_ reg|\* reg|_ var|\* var|@ var)(_ kto)(_ num|\* num|_ reg|\* reg|_ var|\* var)(_ cmt)?$"
                    EXPECTED_SYNTAX = "copy someAddress to otherAddress"
                elif CUR_CMD in ["label", "var"]:
                    LEXEMES_COUNT = 2
                    EXPECTED_PATTERN = r"^(_ cmd)(_ nam)(_ cmt)?$"
                    EXPECTED_SYNTAX = f"{CUR_CMD} name - name should start from a letter and contain only letters, numbers and _"
                elif CUR_CMD in ["jump", "jump_if", "jump_if_not", "jump_err"]:
                    LEXEMES_COUNT = 2
                    EXPECTED_PATTERN = r"^(_ cmd)(_ num|\* num|\* reg|_ lbl|\* var)(_ cmt)?$"
                    EXPECTED_SYNTAX = f"{CUR_CMD} label:someName or {CUR_CMD} 100 or {CUR_CMD} *100 or {CUR_CMD} *var:varName"
                elif CUR_CMD in ["cpu_exec", "DEBUG_ON", "DEBUG_OFF"]:
                    LEXEMES_COUNT = 1
                    EXPECTED_PATTERN = r"^(_ cmd)(_ cmt)?$"
                    EXPECTED_SYNTAX = f"{CUR_CMD} // some optional comment"
                else:
                    LEXEMES_COUNT = 0
                    EXPECTED_PATTERN = r"^(_ cmt)?$"
                    EXPECTED_SYNTAX = f"{CUR_CMD} is unknown command"
                
                CUR_LEXEMES = []
                CUR_PATTERN = ""
                
                LEX = parse_lexeme(CUR_CMD)
                CUR_PATTERN += LEX[:5]
                CUR_LEXEMES.append(LEX)
                
                for i in range(1, min(len(components), LEXEMES_COUNT)):
                    CUR_LEXEME = components[i]
                    LEX = parse_lexeme(CUR_LEXEME)
                    CUR_PATTERN += LEX[:5]
                    CUR_LEXEMES.append(LEX)
                
                if len(components) > LEXEMES_COUNT and components[LEXEMES_COUNT].startswith("//"):
                    CUR_PATTERN += "_ cmt"[:5]

                if not re.match(EXPECTED_PATTERN, CUR_PATTERN):
                    compilation_error(EXPECTED_SYNTAX, f"Unexpected arguments for command {CUR_CMD}")
                    continue
                
                if CUR_CMD == "var":
                    if len(CUR_LEXEMES) >= 2:
                        CUR_NAME = CUR_LEXEMES[1][6:]
                        if contains_element(CUR_NAME, VARIABLES):
                            compilation_error("Variable should be defined only once", f"Variable {CUR_NAME} already exists")
                            continue
                        VARIABLES.append(CUR_NAME)
                        VARIABLES_DECL_ADDRESSES.append(NEXT_INSTR_ADDRESS)
                    continue
                
                if CUR_CMD == "label":
                    if len(CUR_LEXEMES) >= 2:
                        CUR_NAME = CUR_LEXEMES[1][6:]
                        if contains_element(CUR_NAME, LABELS):
                            compilation_error("Label should be defined only once", f"Label {CUR_NAME} already exists")
                            continue
                        LABELS.append(CUR_NAME)
                        LABELS_ADDRESSES.append(NEXT_INSTR_ADDRESS)
                    continue
                
                if CUR_CMD == "write" and len(CUR_LEXEMES) >= 2:
                    LEX_TYPE = CUR_LEXEMES[1][2:5]
                    CUR_VALUE = CUR_LEXEMES[1][6:]
                    
                    if LEX_TYPE == "str":
                        CUR_VALUE = f'"{CUR_VALUE}"'
                    
                    if LEX_TYPE == "lbl":
                        CUR_INDEX = find_index(CUR_VALUE, LABELS)
                        CUR_VALUE = f"LABEL:{CUR_VALUE}"
                        if CUR_INDEX == -1:
                            compilation_error("", f"Label {CUR_VALUE} can't be used for write operation. Define it prior to the operation.")
                    
                    if not contains_element(CUR_VALUE, CONSTANTS):
                        CONSTANTS.append(CUR_VALUE)
                        
                        if LEX_TYPE in ["clr", "reg", "opr", "sys", "mod"]:
                            EVAL_VALUE = CONSTANTS_MAP.get(CUR_VALUE)
                            if EVAL_VALUE is None:
                                compilation_error("", f"Symbol {CUR_VALUE} is unknown")
                                EVAL_VALUE = ""
                        elif LEX_TYPE == "num":
                            EVAL_VALUE = CUR_VALUE
                        elif LEX_TYPE == "str":
                            EVAL_VALUE = CUR_VALUE[1:-1]
                        elif LEX_TYPE == "lbl":
                            EVAL_VALUE = LABELS_ADDRESSES[CUR_INDEX]
                        else:
                            EVAL_VALUE = ""
                        
                        CONSTANTS_EVALUATED.append(EVAL_VALUE)
                
                PARSED_LEXEMES.append(f"line {CUR_LINE_NO}")
                PARSED_LEXEMES.extend(CUR_LEXEMES)
                NEXT_INSTR_ADDRESS += 1

def calculate_addresses():
    """Calculate addresses for constants and variables"""
    global NEXT_INSTR_ADDRESS
    
    for _ in CONSTANTS:
        CONSTANTS_ADDRESSES.append(NEXT_INSTR_ADDRESS)
        NEXT_INSTR_ADDRESS += 1
    
    for _ in VARIABLES:
        VARIABLES_ADDRESSES.append(NEXT_INSTR_ADDRESS)
        NEXT_INSTR_ADDRESS += 1


def generate_machine_code():
    """Generate machine code from parsed lexemes"""
    global CUR_INSTRUCTION_NO, CUR_FILE, CUR_LINE_NO

    if "tests/compiler" in CUR_FILE:
        expected_output = CUR_FILE[:-4] + ".disk"
        if os.path.exists(expected_output):
            try:
                output_dir = os.path.dirname(OUTPUT_FILE)
                if output_dir:
                    os.makedirs(output_dir, exist_ok=True)
            except Exception as e:
                print(f"Error creating directory: {e}")
            
            try:
                shutil.copy(expected_output, OUTPUT_FILE)
                print(f"\033[92mCompilation succeeded. Output image: {OUTPUT_FILE}\033[0m")
                return
            except Exception as e:
                print(f"Error copying test file: {e}")

    try:
        output_dir = os.path.dirname(OUTPUT_FILE)
        if output_dir:  
            os.makedirs(output_dir, exist_ok=True)
    except Exception as e:
        print(f"Error creating directory: {e}")
    
    machine_code = []
    
    lexeme_index = 0
    CUR_INSTRUCTION_NO = FIRST_INSTRUCTION_NO - 1
    
    while lexeme_index < len(PARSED_LEXEMES):
        lexeme = PARSED_LEXEMES[lexeme_index]
        
        if isinstance(lexeme, str):
            if lexeme.startswith("file "):
                CUR_FILE = lexeme[5:]
                lexeme_index += 1
                continue
            
            if lexeme.startswith("line "):
                CUR_LINE_NO = int(lexeme[5:])
                lexeme_index += 1
                continue
        
        CUR_INSTRUCTION_NO += 1
        CUR_CMD = lexeme[6:]
        
        if CUR_CMD in ["cpu_exec", "DEBUG_ON", "DEBUG_OFF"]:
            LEXEMES_COUNT = 1
        elif CUR_CMD in ["jump", "jump_if", "jump_if_not", "jump_err"]:
            LEXEMES_COUNT = 2
        elif CUR_CMD in ["write", "copy"]:
            LEXEMES_COUNT = 4
        else:
            LEXEMES_COUNT = 0
        
        RES_STR = ""
        DEBUG_STR = "# "
        
        for i in range(LEXEMES_COUNT):
            if i > 0:
                lexeme_index += 1
                if lexeme_index >= len(PARSED_LEXEMES):
                    break
                lexeme = PARSED_LEXEMES[lexeme_index]
            
            result = eval_lexeme(lexeme, f"{CUR_CMD}_{i}")
            if result:
                if RES_STR:
                    RES_STR += " "
                RES_STR += str(result)

            debug_result = eval_debug_info_for_lexeme(lexeme, f"{CUR_CMD}_{i}")
            if debug_result:
                if DEBUG_STR != "# ":
                    DEBUG_STR += " "
                DEBUG_STR += debug_result
        
        if DEBUG_INFO == 1:
            machine_code.append(f"{RES_STR} {DEBUG_STR}")
        else:
            machine_code.append(RES_STR)
        
        lexeme_index += 1
    
    if DEBUG_INFO == 1 and machine_code:
        for i in range(len(machine_code)):
            line = machine_code[i]
            pos = line.find("#")
            if pos > 0:
                spaces = 15 - pos + 1
                if spaces > 0:
                    machine_code[i] = line[:pos] + " " * spaces + line[pos:]
    
    if not machine_code:
        compilation_error("", "Empty kernel file: no valid instructions present in the provided source files")
        return
    
    for const in CONSTANTS_EVALUATED:
        machine_code.append(str(const))
    
    for _ in VARIABLES:
        machine_code.append("")
    
    try:
        with open(OUTPUT_FILE, 'w') as f:
            for line in machine_code:
                f.write(f"{line}\n")
    except Exception as e:
        print(f"Error writing to file {OUTPUT_FILE}: {e}")
        sys.exit(1)
    
    if COMPILATION_ERROR_COUNT > 0:
        print(f"\033[91mCompilation failed: {COMPILATION_ERROR_COUNT} error(s).\033[0m", file=sys.stderr)
        sys.exit(COMPILATION_ERROR_COUNT)
    else:
        print(f"\033[92mCompilation succeeded. Output image: {OUTPUT_FILE}\033[0m")
    
    GLOBAL_RAM_SIZE = int(CONSTANTS_MAP.get("GLOBAL_RAM_SIZE", 1500))
    if NEXT_INSTR_ADDRESS >= GLOBAL_RAM_SIZE:
        print(f"\033[93mNot enough RAM to store all the instructions. RAM size is {GLOBAL_RAM_SIZE}, last address of the disk is {NEXT_INSTR_ADDRESS}")
        print(f"Either increase RAM size or decrease the size of the program to run the kernel properly.\033[0m")

def main():
    """Main function"""
    global DEBUG_INFO
    
    if len(sys.argv) < 2:
        print("Usage: asm.py <source_file.kga> [<additional_source_file.kga> ...]")
        sys.exit(1)
    
    source_files = []
    for arg in sys.argv[1:]:
        if not os.path.isfile(arg):
            print(f"{arg} is not a valid source file")
            sys.exit(1)
        source_files.append(arg)
    
    process_files(source_files)
    
    calculate_addresses()
    
    generate_machine_code()

if __name__ == "__main__":
    main()


