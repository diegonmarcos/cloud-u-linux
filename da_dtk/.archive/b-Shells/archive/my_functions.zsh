#!/usr/bin/env zsh


path_to_my_git="/home/diego/Documents/Git/"
#path_to_my_git="/sgoinfre/goinfre/Perso/dinepomu/MyFiles_/git/"

### Colors
rst="\e[0m"
red="\e[1;31m"
green="\e[1;32m"
yellow="\e[1;33m"
blue="\e[1;34m"
magenta="\e[1;35m"
cyan="\e[1;36m"
gray="\e[1;30m"
white="\e[1;37m"
bold="\e[1m"
italic="\e[3m"
underlined="\e[4m"
strikethrough="\e[9m"

### MYHELPER
function myhelp {
	printf "\n\n\n$green##########################"
	printf "\n$green####### MYHELPER #########"
	printf "\n$green##########################$rst\n"
	printf "\n$underlined Functions sh List:$rst"
	printf "\n * c, cx, cv, cdb"
	printf "\n * cl, clx, clv, cldb, cldbg"
	printf "\n * ce"
	printf "\n * code_cleaner, clean_debuger, file_consol_lns"
	printf "\n * ansi_colors\n"
	printf "\n$underlined Syntaxes:$rst"
	printf "\n Compile, Include Lib and Execute:$rst"
	printf "\n$bold  clx <source.c> [args...]$rst\n"
	printf "\n Compile, Include Lib and Varlgrind:$rst"
	printf "\n$bold  clv <source.c> {test_name|-} {infile_stdin|-} [args...]$rst\n"
	printf "\n Compile, Include Lib and Debug:$rst"
	printf "\n$bold  cldb <source.c> [args...]$rst\n"
}

### COMPILERS no LIB
# --- Compile FILES
function c {
	clang -g3 "$@" -o "$(basename "$1" .c).out"
}

# --- Compile FILE+ARG and Execute
function cx {
  clang -g3 "$1" -o "$(basename "$1" .c).out"
  ./"$(basename "$1" .c).out" "${@:2}"
}

# --- Compile FILE+ARG with Library and Execute
### cv [file.c] - - [args]
### or
### cv [file.c] [test_name] [infile_stdin] [args]
### 	$1		$2			$3				$4
function cv {
### Variables
	if [[ "$1" = "help" ]]; then
		echo -e "\n$yellow##########################"
		echo -e "####### CV HELP ###########"
		echo -e "##########################$rst\n"
		echo -e "$underlined Syntax:$rst"
		echo -e "$bold cv <source.c> {test_name|-} {infile_stdin|-} [args...]$rst\n"
		echo -e "$underlined Examples:$rst"
		echo -e " cv file.c - - arg1"
		echo -e "  or"
		echo -e " cv file.c crazy_input log/infile_stdin arg1 arg2 arg3"
		echo -e "\n$underlined Notes:$rst"
		echo -e "$gray<> mandatory, [] optional, {|} mutually exclusive, ... expandable$rst"
		echo -e "\n"
		return
	fi
	source_file=$1
	test_name=$2
	if [[ "$2" == '-' ]]; then
		test_name=$4
	fi
	infile_stdin="$3"
	args="${@:4}"

	valg_filename="log/valgrind_$test_name.log"
	valg_outfile="--log-file=$valg_filename"
	
	valg_flags_fd="--track-fds=yes"
	valg_flags_fork="--trace-children=yes"

	valg_flags_memcheck="-s --leak-check=full --show-leak-kinds=all --track-origins=yes --show-mismatched-frees=yes" 
	valg_memcheck="$valg_outfile $valg_flags_memchk $valg_flags_fd $valg_flags_fork"

	valg_threads2="--tool=threadcheck"
	valg_threads1="--tool=drd"
	valg_threads0="--tool=helgrind"
	valg_threads=$valg_threads0
	valg_threads="$valg_outfile $valg_threads $valg_flags_fd $valg_flags_fork"
	
	program="./$(basename "$source_file" .c).out"
	outfile_stdout="log/outfile_$test_name.log"
	std_out="$outfile_stdout 2>&1 ; echo \"\nReturn: $?\" >> $outfile_stdout 2>&1"


	red="\e[1;31m"
	rst="\e[0m"

### Main
#### Compile
	clang -g3 $source_file -o "$(basename "$source_file" .c).out"

#### Execute Valgrind
	mkdir -p log
	if [[ "$infile_stdin" == '-' ]]; then
		eval "valgrind ${valg_memcheck} ${program} ${args} > ${std_out}"
	else
		eval "valgrind ${valg_memcheck} ${program} ${args} < ${infile_stdin} > ${std_out}"
	fi
	echo -e "\n==      == PROGRAM INPUT ===\n" >> $valg_filename ; echo "$args\n" >> $valg_filename
	echo -e "\n==      == PROGRAM OUTPUT ===\n" >> $valg_filename ; cat $outfile_stdout >> $valg_filename

#### Print Valgrind Report
	echo -e "\n\n\n$red##########################"
	echo -e "##### Valgrind Test #######"
	echo -e "##########################$rst\n"

	echo "\n$red=== PROGRAM OUTPUT ===$rst"
	grep -A 4 "PROGRAM OUTPUT" $valg_filename

	echo "\n$red=== HEAP SUMMARY ===$rst"
    grep -A 4 "HEAP SUMMARY" $valg_filename

	echo "\n$red=== LEAK SUMMARY ===$rst"
    grep -A 7 "LEAK SUMMARY" $valg_filename
    
	echo "\n$red=== FILE DESCRIPTORS ===$rst"
    grep -A 0 "FILE DESCRIPTORS" $valg_filename

	echo "\n$red=== ERRORS ===$rst"
	grep -B 1 -A 2 "at 0x" $valg_filename

}

# --- Valgrind Test Generator using cv function, each line of the while be parsed using sed or awk to be a input for cv function
function cv_test {
	# --- Variables
	source_file="$1"
	infile_test="$2"

	# --- Main
	echo -e "== VALGRIND TEST ===\n\n"

	while read -r args; do
		cv $source_file $args
	done < $infile_test
}


### COMPILERS WITH LIB
# --- Compile FILES with Library
function cl {
	lib_header="${path_to_my_git}mylibs/mylibc/inc"
	lib_addss="${path_to_my_git}mylibs/mylibc"
	lib_name="mylibc"
	clang -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "$(basename "$1" .c).out"
	./"$(basename "$1" .c).out" "${@}"
}

# --- Compile FILE+ARG with Library and Execute
function clx {
	lib_header="${path_to_my_git}mylibs/mylibc/inc"
	lib_addss="${path_to_my_git}mylibs/mylibc"
	lib_name="mylibc"
	clang -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "$(basename "$1" .c).out"
	./"$(basename "$1" .c).out" "${@:2}"
}

# --- Compile FILE+ARG with Library and Execute
function clv {
#Variables
	lib_header="${path_to_my_git}mylibs/mylibc/inc"
	lib_addss="${path_to_my_git}mylibs/mylibc"
	lib_name="mylibc"
	valg_args="--leak-check=full --show-leak-kinds=all --track-origins=yes -s --log-file=valgrind_output.txt"
	program="./$(basename "$1" .c).out"
	output=" > /dev/null 2>&1"
	input="${@:2}"
#Main
	clang -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "$(basename "$1" .c).out"
	eval "valgrind ${valg_args} ${program} ${output} ${input}"
	grep "$1": valgrind_output.txt
}



### DEBUG
# --- LLDB
function cdb {
	echo -e "\n\n\n################################################################"
	echo -e "##### CLANG LLDB #####################################################"
	echo -e "# b main or b [function_name]\t# Set a breakpoint at the start of the 'main' function"
	echo -e "# r\t\t# Run the program"
	echo -e "# "
	echo -e "# s\t\t# Step over the current line (execute it as one step)"
	echo -e "# finish\t\t# Step out of the current function"
	echo -e "# "
	echo -e "# n\t\t# Step into the next line (enter functions if called)"
	echo -e "# "
	echo -e "# v\t\t# View all local variables (useful after hitting a breakpoint)"
	echo -e "# bt\t\t# View the current call stack"
	echo -e "# "
	echo -e "# c\t\t# Continue execution after hitting a breakpoint"
	echo -e "# "
	echo -e "# gui\t\t# Launch the LLDB graphical user interface (full screen)"
	echo -e "#######################################################################\n\n"
	output_name="$(basename "$1" .c)_dbD.db.out"
	clang -g3 "$1" -l"${lib_name}" -o "${output_name}"
	lldb ./"${output_name}" "${@:2}" -o "b main" -o "run" -o "v"
}

# --- CLANG_LLDB
function cldb {
	echo -e "\n\n\n################################################################"
	echo -e "##### CLANG LLDB #####################################################"
	echo -e "# b main or b [function_name]\t# Set a breakpoint at the start of the 'main' function"
	echo -e "# r\t\t# Run the program"
	echo -e "# "
	echo -e "# s\t\t# Step over the current line (execute it as one step)"
	echo -e "# finish\t# Step out of the current function"
	echo -e "# "
	echo -e "# n\t\t# Step into the next line (enter functions if called)"
	echo -e "# "
	echo -e "# v\t\t# View all local variables (useful after hitting a breakpoint)"
	echo -e "# bt\t\t# View the current call stack"
	echo -e "# "
	echo -e "# c\t\t# Continue execution after hitting a breakpoint"
	echo -e "# "
	echo -e "# gui\t\t# Launch the LLDB graphical user interface (full screen)"
	echo -e "#######################################################################\n\n"
	output_name="$(basename "$1" .c)_dbD.db.out"
	lib_header="${path_to_my_git}mylibs/mylibc/inc"
	lib_addss="${path_to_my_git}mylibs/mylibc"
	lib_name="mylibc"
	clang -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "${output_name}"
	lldb ./"${output_name}" "${@:2}" -o "b main" -o "run" -o "v"
}

# --- GCC_GDB
function cldbg {
	echo -e "\n\n\n################################################################"
	echo -e "##### GCC GDB #####################################################"
	echo -e "# b main or b [function_name]\t# Set a breakpoint at the start of the 'main' function"
	echo -e "# r\t\t# Run the program"
	echo -e "# "
	echo -e "# s\t\t# Step INTO the current line (execute it as one step)"
	echo -e "# finish\t\t# Step OUT of the current function"
	echo -e "# "
	echo -e "# n\t\t# Step OVER to the next line (enter functions if called)"
	echo -e "# "
	echo -e "# info locals\t\t# View all local VARIABLES (useful after hitting a breakpoint)"
	echo -e "# info frame \t\t# View all local VARIABLES (useful after hitting a breakpoint)"
	echo -e "# info args\t\t# View all ARGUMENTS (useful after hitting a breakpoint)"
	echo -e "# bt\t\t# View the current call stack"
	echo -e "# "
	echo -e "# c\t\t# CONTINUE execution after hitting a breakpoint"
	echo -e "# "
	echo -e "# gdb -tui your_program"
	echo -e "# tui enable"
	echo -e "#######################################################################\n\n"
	output_name="$(basename "$1" .c)_dbD.db.out"
	lib_header="${path_to_my_git}mylibs/mylibc/inc"
	lib_addss="${path_to_my_git}mylibs/mylibc"
	lib_name="mylibc"
	gcc -g3 "$1" -I"${lib_header}" -L"${lib_addss}" -l"${lib_name}" -o "${output_name}"
	gdb ./"${output_name}" "${@:2}" -ex "b main" -ex "run" -ex "info locals"
}


### MAKE UTILS
# --- CODE CLEANER
function code_cleaner {
	folder="${path_to_my_git}libft_xtend/ft_mylib/src/9_Quality_Assurance/Code_Cleaner"
	file="clean_code.sh"
	"$folder/$file" "$@"
}

# --- CODE CLEANER
function clean_debuger {
	folder="${path_to_my_git}mylibs/mytools/1_coding/make_utils"
	file="clean_debuger.sh"
	"$folder/$file" "$@"
}

# --- Search Recursively and Consolidate with Symb Link
function file_consol_lns {
	folder="${path_to_my_git}mylibs/mytools/1_coding/make_utils"
	file="files_lns.sh"
	"$folder/$file" "$@"
}









# --- Compile and proofing Clang flasg checker
function ce {
  # --- Clang/gcc flags
  echo -e "\n\n\n##########################"
  echo -e "##### Clang Flags ########"
  echo -e "##########################"

  echo -e "\n##Clang Wall Wextra - fsyntaxOnly"
  echo -e "############################################\n"
  clang -fsyntax-only -Wall -Wextra "$1"

  echo -e "\n##Clang Fron-End Semantic - fsyntaxOnly"
  echo -e "############################################\n"
  clang -fsyntax-only -Wformat -Warray-bounds -Wnull-dereference -Wvla -ftrapv "$1" 2>&1

  echo -e "\n###Clang Static Analyzer"
  echo -e "#########################\n"
  clang --analyze -Xanalyzer -analyzer-checker=core "$1" 2>&1

  # --- Run with ASan ---
  echo -e "\n\n\n##########################"
  echo -e "##### ASanitizer #########"
  echo -e "##########################\n\n"
  clang "$1" -o "$(basename "$1" .c)_dbA.db.out" -g -fsanitize=address -fsanitize-recover=address
  ./"$(basename "$1" .c)_dbA.db.out" "${@:2}" 2> asan_output.txt ; grep "$1" asan_output.txt

  # --- Run Valgrind ---
  echo -e "\n\n\n##########################"
  echo -e "##### Valgrind ###########"
  echo -e "##########################\n\n"
  clang "$1" -o "$(basename "$1" .c)_dbV.db.out" -g
  valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes -v --log-file=valgrind_output.txt ./"$(basename "$1" .c)_dbV.db.out" "${@:2}" > /dev/null ; grep "$1": valgrind_output.txt

  rm asan_output.txt
  rm valgrind_output.txt
  rm *.db.out
  rm *.plist
  rm .out

}

# --- ANSI Colors for Bash Script Usage
function ansi_colors {
	rst_text="\e[0m"
	red_text="\e[1;31mRedText\e[0m"
	green_text="\e[1;32mGreen Text\e[0m"
	yellow_text="\e[1;33mYellow Text\e[0m"
	blue_text="\e[1;34mBlue Text\e[0m"
	magenta_text="\e[1;35mMagenta Text\e[0m"
	cyan_text="\e[1;36mCyan Text\e[0m"
	gray_test="\e[1;30mGray Text\e[0m"
	white_text="\e[1;37mWhite Text\e[0m"

	red_bg="\e[41mRed Background\e[0m"
	green_bg="\e[42mGreen Background\e[0m"
	yellow_bg="\e[43mYellow Background\e[0m"
	blue_bg="\e[44mBlue Background\e[0m"
	magenta_bg="\e[45mMagenta Background\e[0m"
	cyan_bg="\e[46mCyan Background\e[0m"
	white_bg="\e[47mWhite Background\e[0m"

	bold_text="\e[1mBold Text\e[0m"
	italic_text="\e[3mItalic Text\e[0m"
	underlined_text="\e[4mUnderlined Text\e[0m"
	strikethrough_text="\e[9mStrikethrough Text\e[0m"

	echo -e "\n\n\n##########################"
	echo -e "##### ANSI Colors ########"
	echo -e "##########################\n"

	echo -e "$red_text"
	echo -e "$green_text"
	echo -e "$yellow_text"
	echo -e "$blue_text"
	echo -e "$magenta_text"
	echo -e "$cyan_text"
	echo -e "$white_text"

	echo -e "\nBackground Colors:"
	echo -e "$red_bg"
	echo -e "$green_bg"
	echo -e "$yellow_bg"
	echo -e "$blue_bg"
	echo -e "$magenta_bg"
	echo -e "$cyan_bg"
	echo -e "$white_bg"

	echo -e "\nText Styles:"
	echo -e "$bold_text"
	echo -e "$italic_text"
	echo -e "$underlined_text"
	echo -e "$strikethrough_text"
}

