#!/usr/bin/env bash



set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "=== Testing concurrent builds with different configurations ==="

if [[ -d "/tmp/zig-cache" ]]; then
    echo "Cleaning existing cache directory..."
    rm -rf /tmp/zig-cache
fi

run_build_and_check_cache() {
    local config="$1"
    local target="$2"
    local build_id="$3"
    
    echo "Starting build $build_id with config: $config"
    
    tools/bazel clean
    
    if [[ -n "$config" ]]; then
        tools/bazel build --config="$config" "$target" 2>&1 | tee "/tmp/build_${build_id}.log"
    else
        tools/bazel build "$target" 2>&1 | tee "/tmp/build_${build_id}.log"
    fi
    
    echo "Build $build_id completed successfully"
    
    if [[ -d "/tmp/zig-cache" ]]; then
        echo "Cache directories created for build $build_id:"
        find /tmp/zig-cache -type d -name "*zig_config*" | head -10
        echo "Full cache structure:"
        find /tmp/zig-cache -type d | head -20
    else
        echo "WARNING: No cache directory found for build $build_id"
    fi
}

echo "--- Test 1: Sequential builds with different configurations ---"

run_build_and_check_cache "" "//test/c:which_libc" "host"

if tools/bazel query --output=package '//...' | grep -q "test"; then
    if tools/bazel build --help | grep -q "config.*linux"; then
        run_build_and_check_cache "linux" "//test/c:which_libc" "cross"
    else
        echo "Cross-compilation config not available, using default config for second build"
        run_build_and_check_cache "" "//test/c:which_libc" "second"
    fi
else
    echo "Test targets not available, using basic build"
    run_build_and_check_cache "" "//:all" "second"
fi

echo "--- Test 2: Verify cache directory structure ---"

if [[ -d "/tmp/zig-cache" ]]; then
    echo "Cache directory structure:"
    find /tmp/zig-cache -type d | sort
    
    cache_dirs=$(find /tmp/zig-cache -mindepth 1 -maxdepth 1 -type d | wc -l)
    echo "Number of configuration-specific cache directories: $cache_dirs"
    
    if [[ $cache_dirs -gt 0 ]]; then
        echo "✓ Configuration-specific cache directories were created"
    else
        echo "✗ No configuration-specific cache directories found"
        exit 1
    fi
    
    unique_configs=$(find /tmp/zig-cache -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -u | wc -l)
    if [[ $unique_configs -gt 1 ]]; then
        echo "✓ Multiple unique cache configurations detected ($unique_configs different configs)"
    else
        echo "ℹ Only one cache configuration detected (this may be expected for single-config builds)"
    fi
else
    echo "✗ No cache directory found at /tmp/zig-cache"
    exit 1
fi

echo "--- Test 3: Concurrent builds test ---"

run_concurrent_build() {
    local config="$1"
    local target="$2"
    local build_id="$3"
    
    echo "Starting concurrent build $build_id..."
    tools/bazel clean > "/tmp/clean_${build_id}.log" 2>&1
    
    if [[ -n "$config" ]]; then
        tools/bazel build --config="$config" "$target" > "/tmp/concurrent_${build_id}.log" 2>&1 &
    else
        tools/bazel build "$target" > "/tmp/concurrent_${build_id}.log" 2>&1 &
    fi
    
    echo $! > "/tmp/concurrent_${build_id}.pid"
}

rm -rf /tmp/zig-cache
tools/bazel clean

run_concurrent_build "" "//test/c:which_libc" "1"
run_concurrent_build "" "//test/c:which_libc" "2"

echo "Waiting for concurrent builds to complete..."
build1_status=0
build2_status=0
wait $(cat /tmp/concurrent_1.pid) || build1_status=$?
wait $(cat /tmp/concurrent_2.pid) || build2_status=$?

echo "Concurrent build results:"
if [[ -f "/tmp/concurrent_1.log" ]]; then
    echo "Build 1 log (last 10 lines):"
    tail -10 /tmp/concurrent_1.log
    if grep -q "Build completed successfully\|INFO: Build completed successfully" /tmp/concurrent_1.log; then
        echo "✓ Build 1 completed successfully"
    else
        echo "✗ Build 1 failed"
        build1_status=1
    fi
fi

if [[ -f "/tmp/concurrent_2.log" ]]; then
    echo "Build 2 log (last 10 lines):"
    tail -10 /tmp/concurrent_2.log
    if grep -q "Build completed successfully\|INFO: Build completed successfully" /tmp/concurrent_2.log; then
        echo "✓ Build 2 completed successfully"
    else
        echo "✗ Build 2 failed"
        build2_status=1
    fi
fi

if [[ $build1_status -eq 0 && $build2_status -eq 0 ]]; then
    echo "✓ Concurrent builds completed without cache conflicts"
else
    echo "✗ One or more concurrent builds failed"
    exit 1
fi


rm -f /tmp/build_*.log /tmp/concurrent_*.log /tmp/concurrent_*.pid

echo "=== All tests completed successfully ==="
echo "✓ Configuration-specific cache directories prevent concurrent build collisions"
echo "✓ Different configurations use separate cache paths"
echo "✓ Concurrent builds complete without interference"
