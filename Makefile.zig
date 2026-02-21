# Zig版 QMK Firmware コマンドランナー
# 使い方: make -f Makefile.zig <target>

.PHONY: build test clean flash fmt

# デフォルトターゲット
all: build

# ビルド（ネイティブ）
build:
	zig build

# テスト実行
test:
	zig build test

# テスト実行（サマリー表示）
test-summary:
	zig build test --summary all

# クリーンビルド
clean:
	rm -rf .zig-cache zig-out

# RP2040ファームウェアビルド（クロスコンパイル）
firmware:
	zig build -Dtarget=thumb-freestanding-eabi

# UF2ファイル生成
uf2: firmware
	zig-out/bin/uf2gen zig-out/bin/firmware.bin zig-out/firmware.uf2

# フラッシュ（RP2040 BOOTSELモード経由）
flash: uf2
	@if [ -d /Volumes/RPI-RP2 ]; then \
		cp zig-out/firmware.uf2 /Volumes/RPI-RP2/; \
		echo "Flashed to RP2040"; \
	elif [ -d /media/$$USER/RPI-RP2 ]; then \
		cp zig-out/firmware.uf2 /media/$$USER/RPI-RP2/; \
		echo "Flashed to RP2040"; \
	else \
		echo "Error: RP2040 not found in BOOTSEL mode"; \
		exit 1; \
	fi

# C版テスト（既存upstream）
test-c:
	qmk test-c

# C版ビルド（既存upstream）
build-c:
	make madbd34:default

# ヘルプ
help:
	@echo "Zig版 QMK Firmware コマンドランナー"
	@echo ""
	@echo "使い方: make -f Makefile.zig <target>"
	@echo ""
	@echo "Zigビルド:"
	@echo "  build          - ビルド（ネイティブ）"
	@echo "  test           - テスト実行"
	@echo "  test-summary   - テスト実行（サマリー表示）"
	@echo "  clean          - ビルドキャッシュ削除"
	@echo "  firmware       - RP2040ファームウェアビルド"
	@echo "  uf2            - UF2ファイル生成"
	@echo "  flash          - フラッシュ書き込み"
	@echo ""
	@echo "C版（upstream）:"
	@echo "  test-c         - C版ユニットテスト"
	@echo "  build-c        - C版ビルド（madbd34）"
