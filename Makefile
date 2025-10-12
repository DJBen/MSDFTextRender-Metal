SWIFTFORMAT ?= swiftformat
FMT_ARGS := --config .swiftformat

.PHONY: format
format:
	@command -v $(SWIFTFORMAT) >/dev/null 2>&1 || { echo "swiftformat not found. Install with: brew install swiftformat"; exit 1; }
	@$(SWIFTFORMAT) $(FMT_ARGS) .

