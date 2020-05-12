#!/usr/bin/env crystal run

# This is a helper script -- it identifies the clang++ binary and possibly
# llvm-config binary, then calls them to retrieve their settings, and parses
# settings for further use.

# As part of the run, it generates some files.
# It outputs all LLVM and Clang libraries to link to.
# Provides diagnostics to standard error.
# This script is called automatically from `Makefile`.
# Can be invoked manually. Invoke with --help for options.

require "yaml"
require "../src/bindgen/util"
require "../src/bindgen/find_path"

UNAME_S = `uname -s`.chomp

parse_cli_args

unless clang_binary = OPTIONS[:clang] || find_clang_binary
  print_help_and_exit
end

log "Found clang binary in #{clang_binary.inspect}. Querying it:"

# Ask clang the paths it uses. This output will then be parsed in detail.
output = log_and_run("#{clang_binary} -### #{__DIR__}/src/bindgen.cpp 2>&1").lines

if output.size < 2 # Sanity check
  STDERR.puts %(Unexpected output from "#{clang_binary}": Expected at least two lines.)
  exit 1
end

# Start parsing the output:

# Untangle the output
raw_cppflags = output[-2].gsub(/^\s+"|\s+"$/, "")
raw_ldflags = output[-1].gsub(/^\s+"|\s+"$/, "")

cppflags = raw_cppflags.split(/"\s+"/)
  .concat(shell_split(ENV.fetch("CPPFLAGS", "")))
  .uniq
ldflags = raw_ldflags.split(/"\s+"/)
  .concat(shell_split(ENV.fetch("LDFLAGS", "")))
  .uniq

system_includes = [] of String
system_libs = [] of String

# Interpret the argument lists
flags = cppflags + ldflags
index = 0
while index < flags.size
  case flags[index]
  when "-internal-isystem"
    system_includes << flags[index + 1]
    index += 1
  when "-resource-dir" # Find paths on Ubuntu
    resource_dir = flags[index + 1]
    system_includes << File.expand_path("#{resource_dir}/../../../include")
    index += 1
  when "-lto_library"
    to_library = flags[index + 1]
    system_libs << to_library.split("/lib/")[0] + "/lib/"
    index += 1
  when /^-L/
    l = flags[index][2..-1]
    l += "/" if l !~ /\/$/
    system_libs << l
  else
  end

  index += 1
end

# Check darwin include dir
if UNAME_S == "Darwin" && Dir.exists?("/usr/local/include/")
  system_includes << "/usr/local/include/"
  # system_includes << "/usr/local/opt/llvm/lib/clang/10.0.0/include/"
end

# Clean libs
system_libs.uniq!
system_libs.map! { |path| File.expand_path(path.gsub(/\/$/, "")) }
system_includes.uniq!
system_includes.map! { |path| File.expand_path(path.gsub(/\/$/, "")) }

# Now extract clang and llvm-specific libs:
clang_libs = find_libraries(system_libs, "clang")
llvm_libs = find_libraries(system_libs, "LLVM")

# Provide user with help if we can't find it.
print_help_and_exit if llvm_libs.empty? || clang_libs.empty?

# See if only partial info was requested:

if OPTIONS[:clang_libs]
  log "Option --clang-libs detected. Printing libraries and exiting."
  STDOUT << get_lib_args(clang_libs).join(";")
  exit
end

if OPTIONS[:llvm_libs]
  log "Option --llvm-libs detected. Printing libraries and exiting."
  STDOUT << get_lib_args(llvm_libs).join(";")
  exit
end

# If this is a full run (i.e. not asking for specific things), continue:

# Generate the output header file.  This will be accessed from the clang tool.
generated_hpp = File.expand_path "#{__DIR__}/include/generated.hpp"
log "Generating #{generated_hpp}"
write_if_changed(generated_hpp, String.build do |b|
  b.puts "// Generated by #{__FILE__}"
  b.puts "// DO NOT CHANGE"
  b.puts
  b.puts "#define BG_SYSTEM_INCLUDES { #{system_includes.map(&.inspect).join(", ")} }"
end)

libs = get_lib_args(clang_libs)
libs += get_lib_args(llvm_libs)

includes = system_includes.map { |x| "-I#{File.expand_path(x)}" }

# Find llvm config if we are using llvm
llvm_config_binary = find_llvm_config_binary system_libs.map { |path| path.gsub(/(lib|include)$/, "bin") }

log "Found llvm-config binary in #{llvm_config_binary.inspect}."

# Generate Makefile.variables file
makefile_variables = File.expand_path "#{__DIR__}/Makefile.variables"
log "Generating #{makefile_variables}"

makefile_variables_content = <<-VARS
  CLANG_BINARY := #{clang_binary}
  CLANG_INCLUDES := #{includes.join(" ")}
  CLANG_LIBS := #{libs.join(" ")}

  VARS

# Get flags from llvm
if !llvm_config_binary.nil? && File.exists?(llvm_config_binary)
  llvm_version = `#{llvm_config_binary} --version`.chomp

  makefile_variables_content += <<-VARS
  LLVM_CONFIG_BINARY := #{llvm_config_binary}
  LLVM_VERSION := #{llvm_version.split(/\./).first}
  LLVM_VERSION_FULL := #{llvm_version}
  VARS

  # Need to add the clang includes if we can find them
  llvm_lib_dir = `#{llvm_config_binary} --libdir`.chomp
  clang_include_dir = File.join(llvm_lib_dir, "clang", llvm_version, "include")
  system_includes << clang_include_dir if File.exists?(clang_include_dir)

  llvm_cxx_flags = `#{llvm_config_binary} --cxxflags`.chomp
    .gsub(/-fno-exceptions/, "")
    .gsub(/-W[^alp].+\s/, "")
    .gsub(/\s+/, " ")
  makefile_variables_content += "\nLLVM_CXX_FLAGS := " + llvm_cxx_flags

  makefile_variables_content +=
    "\nLLVM_LD_FLAGS := " + `#{llvm_config_binary} --ldflags`.chomp
      .gsub(/\s+/, " ")

  makefile_variables_content +=
    "\nLLVM_LIBS := " + get_lib_args(llvm_libs).join(" ")
end

write_if_changed(makefile_variables, makefile_variables_content)

# Generate spec_base.yml
spec_base = File.expand_path "#{__DIR__}/../spec/integration/spec_base.yml"
log "Generating #{spec_base}"

spec_base_content = {
  module:     "Test",
  generators: {
    cpp: {
      output: "tmp/{SPEC_NAME}.cpp",
      build:  "#{clang_binary} #{llvm_cxx_flags} #{includes.join ' '} " \
             " -c -o {SPEC_NAME}.o {SPEC_NAME}.cpp -I.. -Wall -Werror -Wno-unused-function",
      preamble: <<-PREAMBLE
      #include <gc/gc_cpp.h>
      #include "bindgen_helper.hpp"
      PREAMBLE
    },
    crystal: {
      output: "tmp/{SPEC_NAME}.cr",
    },
  },
  library: "%/tmp/{SPEC_NAME}.o -lstdc++",
  parser:  {
    files:    ["{SPEC_NAME}.cpp"],
    includes: [
      "%",
    ].concat(system_includes),
  },
}.to_yaml

write_if_changed(spec_base, spec_base_content)

log "All done."

#################################################
# Helper functions found below.

# Used for quick/ad-hoc option parser
OPTIONS = Hash(Symbol, Bool | String | Nil).new

# Parses command line in an ad hoc way. Could be replaced
# with OptionParser.
def parse_cli_args
  OPTIONS[:llvm_libs] = ARGV.includes?("--llvm-libs")
  OPTIONS[:clang_libs] = ARGV.includes?("--clang-libs")
  OPTIONS[:quiet] = ARGV.includes?("--quiet")
  OPTIONS[:clang_pattern] = "clang++*"
  OPTIONS[:llvm_config_pattern] = "llvm-config*"
  OPTIONS[:clang] = nil

  if ARGV.includes?("--clang")
    index = ARGV.index("--clang")
    OPTIONS[:clang] = ARGV[index + 1] unless index.nil?
  end
  if ARGV.includes?("--clang-pattern")
    index = ARGV.index("--clang-pattern")
    OPTIONS[:clang_pattern] = ARGV[index + 1] unless index.nil?
  end
  if ARGV.includes?("--llvm-config-pattern")
    index = ARGV.index("--llvm-config-pattern")
    OPTIONS[:llvm_config_pattern] = ARGV[index + 1] unless index.nil?
  end
  if ARGV.includes?("--help")
    print_usage_and_exit
  end
end

# Finds clang binary (named 'clang++*' or as specified with
# option --clang-pattern) inside directories in PATH. It must
# satisfy minimum version.
def find_clang_binary : String?
  log %(Searching for binary "#{OPTIONS[:clang_pattern]}" in PATH. Minimum version 6.0.0)
  clang_find_config = <<-YAML
  kind: Executable
  try:
    - "#{OPTIONS[:clang_pattern]}"
  search_paths:
    #{ENV["PATH"].split(/:+/).map { |p| "- \"" + p + "\"" }.join("\n  ")}
  version:
    min: "6.0.0"
    command: "% --version"
    regex: "clang version ([0-9.]+)"
  YAML
  clang_find_config = Bindgen::FindPath::PathConfig.from_yaml clang_find_config

  path_finder = Bindgen::FindPath.new(__DIR__)
  path_finder.find(clang_find_config)
end

# Finds llvm-config binary (named 'llvm-config*' or as specified with
# option --llvm-config-pattern) inside directories in PATH. It must
# satisfy minimum version.
def find_llvm_config_binary(paths) : String?
  log %(Searching for binary "#{OPTIONS[:llvm_config_pattern]}" in clang paths and PATH. Minimum version 6.0.0)
  llvm_config_find_config = <<-YAML
  kind: Executable
  try:
    - "#{OPTIONS[:llvm_config_pattern]}"
  search_paths:
    #{paths.map { |p| "- \"" + p + "\"" }.join("\n  ")}
    #{ENV["PATH"].split(/:+/).map { |p| "- \"" + p + "\"" }.join("\n  ")}
  version:
    min: "6.0.0"
    command: "% --version"
    regex: "([0-9.]+)"
  YAML
  llvm_config_find_config = Bindgen::FindPath::PathConfig.from_yaml llvm_config_find_config

  path_finder = Bindgen::FindPath.new(__DIR__)
  path_finder.find(llvm_config_find_config)
end

# Prints help and exits.
def print_help_and_exit
  STDERR.puts <<-END
  You're missing the LLVM and/or Clang executables or development libraries.

  If you've installed the binaries in a non-standard location:
    1) Make sure that `clang++` and `llvm-config` are in PATH. The first binary found which satisfies version will be used.

  If you have them named differenly than `clang++` and `llvm-config`:
    2) Run the tool with `--clang-pattern <name of clang++> --llvm-config-pattern <name of llvm_config>`

  You can also invoke the tool with argument `--clang /path/to/clang++`. This is how make will call it.

  If your distro does not support static libraries like openSUSE then set env var BINDGEN_DYNAMIC=1.
  This will use .so instead of .a libraries during linking.

  If you are missing the packages, please install them:
    ArchLinux: pacman -S llvm clang gc libyaml
    Ubuntu: apt install clang-4.0 libclang-4.0-dev zlib1g-dev libncurses-dev libgc-dev llvm-4.0-dev libpcre3-dev
    CentOS: yum install crystal libyaml-devel gc-devel pcre-devel zlib-devel clang-devel
    openSUSE: zypper install llvm clang libyaml-devel gc-devel pcre-devel zlib-devel clang-devel ncurses-devel
    Mac OS: brew install crystal bdw-gc gmp libevent libxml2 libyaml llvm
  END

  exit 1
end

def print_usage_and_exit
  STDERR.puts <<-END
    find_clang.cr [options]

    Options:
    --clang PATH         Path to clang binary (default: none)

    --clang-pattern PTRN        Name or pattern of clang binary (default: clang++*)
    --llvm-config-pattern PTRN  Name or pattern of llvm-config (default: llvm-config*)

    --clang-libs         Print found clang libs and exit (default: false)
    --llvm-libs          Print found llvm libs and exit (default: false)

    --quiet              Supress diagnostic/debug STDERR output (default: false)
    --help               This help


  END

  exit 1
end

# Prints message to STDERR unless --quiet is given
def log(message : String)
  unless OPTIONS[:quiet]
    STDERR.puts message
  end
end

# Logs the command line, then runs it and returns output of the backticks
def log_and_run(cmdline : String)
  log cmdline
  `#{cmdline}`
end

# Shell-split. Helper function used in parsing clang output.
def shell_split(line : String)
  list = [] of String
  skip_next = false
  in_string = false
  offset = 0

  # Parse string
  line.each_char_with_index do |char, idx|
    if skip_next
      skip_next = false
      next
    end

    case char
    when '\\' # Escape character
      skip_next = true
    when ' ' # Split character
      unless in_string
        list << line[offset...idx]
        offset = idx + 1
      end
    when '"' # String marker
      in_string = !in_string
    else
    end
  end

  list.reject(&.empty?).map do |x|
    # Remove surrounding double-quotes
    if x.starts_with?('"') && x.ends_with?('"')
      x[1..-2]
    else
      x
    end
  end
end

# Finds all LLVM and clang libraries, and links to them.  We don't need
# all of them - Which totally helps with keeping linking times low.
def find_libraries(paths, prefix)
  if ENV.fetch("BINDGEN_DYNAMIC", "0") == "1"
    paths
      .flat_map { |path| Dir["#{path}/lib#{prefix}*.so"] }
      .map { |path| File.basename(path)[/^lib(.+)\.so$/, 1] }
      .uniq
  else
    paths
      .flat_map { |path| Dir["#{path}/lib#{prefix}*.a"] }
      .map { |path| File.basename(path)[/^lib([^.]+)\.a$/, 1] } # FIXME: this lead to crash for e.g. libclang_rt.msan_cxx-x86_64.a
      .uniq
  end
end

# Gets the list of -l... link arguments.
# Libraries must precede their dependencies. We can use the
# --start-group and --end-group wrappers in linux to get
# the correct order
def get_lib_args(libs_list)
  libs = Array(String).new
  if UNAME_S == "Darwin"
    libs.concat libs_list.map { |x| "-l#{x}" }
  else
    libs << "-Wl,--start-group"
    libs.concat libs_list.map { |x| "-l#{x}" }
    libs << "-Wl,--start-group"
  end
  libs
end

# Writes a file only if its contents are different than already present on disk.
# Only write if there's a change.  Else we break make's dependency caching and
# constantly rebuild everything.
def write_if_changed(path, content)
  if !File.exists?(path) || File.read(path) != content
    File.write(path, content)
    return true
  end
  false
end
