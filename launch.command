#!/bin/sh
cd "$(dirname "$0")" || exit 1
mkdir -p .build
CLANG_MODULE_CACHE_PATH=.build/ModuleCache swiftc TokenPet.swift -o .build/token-pet || exit 1
exec .build/token-pet
