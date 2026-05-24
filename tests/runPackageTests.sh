#!/usr/bin/env bash

set -u
set -o pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
target_input=${1:-$script_dir}

command_available() {
    command -v "$1" >/dev/null 2>&1
}

die() {
    printf '%s\n' "$1" >&2
    exit 1
}

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

add_failure() {
    local -n target_array=$1
    target_array+=("$2")
}

resolve_dir() {
    local path=$1

    [[ -d $path ]] || die "Directory not found: $path"
    (
        cd -- "$path" && pwd -P
    )
}

expect_build=
expect_package=
declare -a expect_absent=()

get_test_case_expectation() {
    local tex_file_path=$1
    local line absent_values

    expect_build=
    expect_package=
    expect_absent=()

    while IFS= read -r line; do
        [[ $line =~ ^[[:space:]]*$ ]] && continue

        if [[ ! $line =~ ^[[:space:]]*%[[:space:]]*pdfprivacy-test:[[:space:]]* ]]; then
            break
        fi

        if [[ $line =~ ^[[:space:]]*%[[:space:]]*pdfprivacy-test:[[:space:]]*build=(success|fail)[[:space:]]+package=(none|warning|error)[[:space:]]*$ ]]; then
            expect_build=${BASH_REMATCH[1]}
            expect_package=${BASH_REMATCH[2]}
            continue
        fi

        if [[ $line =~ ^[[:space:]]*%[[:space:]]*pdfprivacy-test:[[:space:]]*absent=(.+?)[[:space:]]*$ ]]; then
            absent_values=${BASH_REMATCH[1]}
            IFS=',' read -r -a absent_parts <<< "$absent_values"
            for absent_tag in "${absent_parts[@]}"; do
                expect_absent+=("$(trim "$absent_tag")")
            done
            continue
        fi

        die "Invalid pdfprivacy-test header in $tex_file_path. Expected directives like % pdfprivacy-test: build=success package=none or % pdfprivacy-test: absent=PDF:Author,PDF:Title."
    done < <(head -n 12 -- "$tex_file_path")

    [[ -n $expect_build && -n $expect_package ]] || die "Missing pdfprivacy-test build/package directive in $tex_file_path. Expected % pdfprivacy-test: build=(success|fail) package=(none|warning|error) before the document content."

    if [[ $expect_build == success && ${#expect_absent[@]} -eq 0 ]]; then
        die "Missing pdfprivacy-test absent directive in $tex_file_path. Successful tests must declare which metadata entries must be absent."
    fi
}

test_expected_package_diagnostics() {
    local combined_build_output=$1
    local package_expectation=$2

    case $package_expectation in
        none)
            ! grep -Eq 'Package[[:space:]]+pdfprivacy[[:space:]]+(Warning|Error):' <<< "$combined_build_output"
            ;;
        warning)
            grep -Eq 'Package[[:space:]]+pdfprivacy[[:space:]]+Warning:' <<< "$combined_build_output"
            ;;
        error)
            grep -Eq 'Package[[:space:]]+pdfprivacy[[:space:]]+Error:' <<< "$combined_build_output"
            ;;
        *)
            die "Unknown package expectation '$package_expectation'"
            ;;
    esac
}

update_pdfprivacy_style_run_marker() {
    local style_path=$1
    local marker=$2
    local marker_file tmp_file marker_block

    [[ -f $style_path ]] || die "Style file not found: $style_path"

    marker_file=$(mktemp) || die "Failed to create temporary marker file while updating $style_path"
    marker_block=$(cat <<'EOF'
% PDFPRIVACY_TESTRUN_MARKER_BEGIN
\AtBeginDocument{%
\wlog{__PDFPRIVACY_MARKER__}%
\message{__PDFPRIVACY_MARKER__}%
}
% PDFPRIVACY_TESTRUN_MARKER_END
EOF
)
    marker_block=${marker_block//__PDFPRIVACY_MARKER__/$marker}
    printf '%s\n' "$marker_block" > "$marker_file"
    tmp_file=$(mktemp) || die "Failed to create temporary file while updating $style_path"

    if ! awk -v marker_path="$marker_file" '
        function print_marker_block(    marker_line) {
            while ((getline marker_line < marker_path) > 0) {
                print marker_line
            }
            close(marker_path)
        }
        BEGIN {
            inblock = 0
            replaced = 0
            endinput_seen = 0
        }
        $0 == "% PDFPRIVACY_TESTRUN_MARKER_BEGIN" {
            inblock = 1
            if (!replaced) {
                print_marker_block()
                replaced = 1
            }
            next
        }
        inblock && $0 == "% PDFPRIVACY_TESTRUN_MARKER_END" {
            inblock = 0
            next
        }
        inblock {
            next
        }
        $0 == "\\endinput" {
            if (!replaced) {
                print_marker_block()
                print ""
                replaced = 1
            }
            endinput_seen = 1
            print
            next
        }
        {
            print
        }
        END {
            if (!endinput_seen || !replaced) {
                exit 2
            }
        }
    ' "$style_path" > "$tmp_file"; then
        rm -f -- "$marker_file"
        rm -f -- "$tmp_file"
        die "Failed to update run marker in $style_path"
    fi

    rm -f -- "$marker_file"
    mv -- "$tmp_file" "$style_path"
}

declare -A metadata_values=()
declare -a metadata_keys=()

load_metadata() {
    local pdf_path=$1
    local line group tag value key

    metadata_values=()
    metadata_keys=()

    while IFS= read -r line; do
        if [[ $line =~ ^\[([^]]+)\][[:space:]]+([^:]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
            group=${BASH_REMATCH[1]}
            tag=$(trim "${BASH_REMATCH[2]}")
            value=${BASH_REMATCH[3]}
            key="$group:$tag"
            metadata_values["$key"]=$value
            metadata_keys+=("$key")
        fi
    done < <(exiftool -a -G1 -s "$pdf_path")
}

declare -a failed_checks=()

test_expected_metadata_absence() {
    local pdf_path=$1
    shift

    local tag key value verbose_metadata
    failed_checks=()

    for tag in "$@"; do
        if [[ $tag =~ ^(PDF:TrailerID|TrailerID|pdftrailerid)$ ]]; then
            verbose_metadata=$(exiftool -v3 "$pdf_path" 2>&1)
            if [[ $? -ne 0 ]]; then
                failed_checks+=("Unable to inspect trailer ID with exiftool -v3")
            elif grep -Eq '^[[:space:]]*[0-9]+\)[[:space:]]+ID[[:space:]]*=[[:space:]]*\[' <<< "$verbose_metadata"; then
                failed_checks+=("PDF trailer ID is still present")
            fi
            continue
        fi

        if [[ $tag == *'*'* || $tag == *'?'* ]]; then
            local matches=()
            for key in "${metadata_keys[@]}"; do
                if [[ $key == $tag ]]; then
                    matches+=("$key")
                fi
            done

            if [[ ${#matches[@]} -gt 0 ]]; then
                failed_checks+=("Metadata keys still present: $(IFS=', '; printf '%s' "${matches[*]}")")
            fi
            continue
        fi

        if [[ ${metadata_values[$tag]+set} ]]; then
            value=${metadata_values[$tag]}
            if [[ -n $value ]]; then
                failed_checks+=("$tag has value '$value'")
            fi
        fi
    done
}

if ! command_available latexmk; then
    die "latexmk was not found in PATH. Install TeX with latexmk and try again."
fi

if ! command_available exiftool; then
    die "exiftool was not found in PATH. Install ExifTool and try again."
fi

target_path=$(resolve_dir "$target_input")
repo_root=$(resolve_dir "$script_dir/..")
pdfprivacy_style_path="$repo_root/pdfprivacy.sty"

if [[ -r /proc/sys/kernel/random/uuid ]]; then
    test_run_id=$(tr -d '-' < /proc/sys/kernel/random/uuid)
elif command_available uuidgen; then
    test_run_id=$(uuidgen | tr -d '-')
else
    die "Unable to generate a test run ID. Install uuidgen or provide /proc/sys/kernel/random/uuid."
fi

test_run_marker="PDFPRIVACY-TESTRUN-ID:$test_run_id"

engine_names=(latex xelatex lualatex)
engine_flags=(-pdf -xelatex -lualatex)

declare -a selected_engine_names=()
declare -a selected_engine_flags=()
declare -a selected_engine_roots=()

target_leaf=${target_path##*/}
target_leaf_lower=${target_leaf,,}

for index in "${!engine_names[@]}"; do
    if [[ ${engine_names[$index]} == "$target_leaf_lower" ]]; then
        selected_engine_names+=("${engine_names[$index]}")
        selected_engine_flags+=("${engine_flags[$index]}")
        selected_engine_roots+=("$target_path")
        break
    fi
done

if [[ ${#selected_engine_names[@]} -eq 0 ]]; then
    for index in "${!engine_names[@]}"; do
        engine_root="$target_path/${engine_names[$index]}"
        if [[ -d $engine_root ]]; then
            selected_engine_names+=("${engine_names[$index]}")
            selected_engine_flags+=("${engine_flags[$index]}")
            selected_engine_roots+=("$engine_root")
        fi
    done
fi

if [[ ${#selected_engine_names[@]} -eq 0 ]]; then
    die "No engine testcase folders found under $target_path. Expected one or more of: latex, xelatex, lualatex"
fi

texinputs_was_set=0
original_texinputs=
if [[ ${TEXINPUTS+x} ]]; then
    texinputs_was_set=1
    original_texinputs=$TEXINPUTS
fi

restore_texinputs() {
    if [[ $texinputs_was_set -eq 1 ]]; then
        export TEXINPUTS=$original_texinputs
    else
        unset TEXINPUTS
    fi
}

trap restore_texinputs EXIT

update_pdfprivacy_style_run_marker "$pdfprivacy_style_path" "$test_run_marker"
printf 'Using test run ID: %s\n' "$test_run_id"

if [[ $texinputs_was_set -eq 1 && -n $original_texinputs ]]; then
    export TEXINPUTS="$repo_root:$original_texinputs"
else
    export TEXINPUTS="$repo_root:"
fi

declare -a case_engine_names=()
declare -a case_build_flags=()
declare -a case_tex_files=()

for index in "${!selected_engine_names[@]}"; do
    while IFS= read -r -d '' tex_file; do
        case_engine_names+=("${selected_engine_names[$index]}")
        case_build_flags+=("${selected_engine_flags[$index]}")
        case_tex_files+=("$tex_file")
    done < <(find "${selected_engine_roots[$index]}" -maxdepth 1 -type f -name '*.tex' -print0 | sort -z)
done

if [[ ${#case_tex_files[@]} -eq 0 ]]; then
    printf 'No .tex files found under selected engine folders.\n'
    exit 0
fi

declare -a clean_failures=()
declare -a latex_failures=()
declare -a style_marker_failures=()
declare -a package_expectation_failures=()
declare -a pdf_missing=()
declare -a metadata_failures=()
declare -a skipped_tests=()

for index in "${!case_tex_files[@]}"; do
    tex_file=${case_tex_files[$index]}
    engine_name=${case_engine_names[$index]}
    build_flag=${case_build_flags[$index]}
    tex_dir=$(dirname -- "$tex_file")
    tex_name=$(basename -- "$tex_file")
    pdf_path=${tex_file%.tex}.pdf
    case_label="[$engine_name] $tex_file"

    get_test_case_expectation "$tex_file"

    printf '\n=== Cleaning %s ===\n' "$case_label"
    if ! (
        cd -- "$tex_dir" &&
        latexmk "$build_flag" -C "$tex_name"
    ); then
        add_failure clean_failures "$case_label"
        continue
    fi

    printf '\n=== Building %s ===\n' "$case_label"
    build_output=$(
        cd -- "$tex_dir" &&
        latexmk "$build_flag" -interaction=nonstopmode -halt-on-error "$tex_name" 2>&1
    )
    build_exit_code=$?
    printf '%s\n' "$build_output"

    if test_expected_package_diagnostics "$build_output" "$expect_package"; then
        package_matches_expectation=1
    else
        package_matches_expectation=0
    fi

    if [[ $build_exit_code -ne 0 ]]; then
        if [[ $expect_build == fail && $package_matches_expectation -eq 1 ]]; then
            continue
        fi

        add_failure package_expectation_failures "$case_label -> build failed but directive expected '$expect_build' and package severity '$expect_package' was not satisfied"
        continue
    fi

    if [[ $expect_build == fail ]]; then
        add_failure package_expectation_failures "$case_label -> build succeeded but directive expected failure"
        continue
    fi

    if [[ $package_matches_expectation -ne 1 ]]; then
        add_failure package_expectation_failures "$case_label -> package diagnostic did not match expected '$expect_package' severity"
        continue
    fi

    if ! grep -Fq "$test_run_marker" <<< "$build_output"; then
        add_failure style_marker_failures "$case_label -> run marker '$test_run_marker' not found in latexmk output"
        continue
    fi

    if [[ ! -f $pdf_path ]]; then
        add_failure pdf_missing "$case_label -> Expected PDF not found: $pdf_path"
        continue
    fi

    printf '\n=== Metadata for %s [%s] ===\n' "$(basename -- "$pdf_path")" "$engine_name"
    exiftool -a -G1 -s "$pdf_path"

    load_metadata "$pdf_path"
    test_expected_metadata_absence "$pdf_path" "${expect_absent[@]}"

    if [[ ${#failed_checks[@]} -gt 0 ]]; then
        add_failure metadata_failures "$case_label -> $(IFS='; '; printf '%s' "${failed_checks[*]}")"
    fi
done

printf '\n=== Summary ===\n'
printf 'Processed TeX files: %s\n' "${#case_tex_files[@]}"
printf 'Clean failures: %s\n' "${#clean_failures[@]}"
printf 'LaTeX build failures: %s\n' "${#latex_failures[@]}"
printf 'Style marker failures: %s\n' "${#style_marker_failures[@]}"
printf 'Package expectation failures: %s\n' "${#package_expectation_failures[@]}"
printf 'Missing PDFs: %s\n' "${#pdf_missing[@]}"
printf 'Metadata assertion failures: %s\n' "${#metadata_failures[@]}"
printf 'Skipped tests: %s\n' "${#skipped_tests[@]}"

if [[ ${#package_expectation_failures[@]} -gt 0 ]]; then
    printf '\nPackage expectation failures:\n'
    printf -- '- %s\n' "${package_expectation_failures[@]}"
fi

if [[ ${#clean_failures[@]} -gt 0 ]]; then
    printf '\nClean failures:\n'
    printf -- '- %s\n' "${clean_failures[@]}"
fi

if [[ ${#latex_failures[@]} -gt 0 ]]; then
    printf '\nBuild failures:\n'
    printf -- '- %s\n' "${latex_failures[@]}"
fi

if [[ ${#style_marker_failures[@]} -gt 0 ]]; then
    printf '\nStyle marker failures:\n'
    printf -- '- %s\n' "${style_marker_failures[@]}"
fi

if [[ ${#pdf_missing[@]} -gt 0 ]]; then
    printf '\nMissing PDFs:\n'
    printf -- '- %s\n' "${pdf_missing[@]}"
fi

if [[ ${#metadata_failures[@]} -gt 0 ]]; then
    printf '\nMetadata assertion failures:\n'
    printf -- '- %s\n' "${metadata_failures[@]}"
fi

if [[ ${#skipped_tests[@]} -gt 0 ]]; then
    printf '\nSkipped tests:\n'
    printf -- '- %s\n' "${skipped_tests[@]}"
fi

if [[ $((${#clean_failures[@]} + ${#latex_failures[@]} + ${#style_marker_failures[@]} + ${#package_expectation_failures[@]} + ${#pdf_missing[@]} + ${#metadata_failures[@]})) -gt 0 ]]; then
    exit 1
fi

exit 0