class_name OutputBuffer
extends RefCounted


## OutputBuffer - Frame-gated output buffering for terminal panels
##
## Buffers incoming agent output and delivers it in batches per frame
## to prevent frame drops during high-output periods. Implements
## time-slicing to ensure rendering stays within budget.


# =============================================================================
# Constants
# =============================================================================

## Maximum bytes to process per frame to stay within frame budget
const MAX_BYTES_PER_FRAME := 4096

## Maximum accumulated buffer size before force-flush
const MAX_BUFFER_SIZE := 65536

## Time budget per frame for output processing (ms)
const FRAME_TIME_BUDGET_MS := 2.0


# =============================================================================
# State
# =============================================================================

var _buffer: String = ""
var _pending_flush: bool = false
var _total_bytes_buffered: int = 0
var _last_flush_frame: int = 0
var _callback: Callable


# =============================================================================
# Initialization
# =============================================================================

func _init(flush_callback: Callable) -> void:
	_callback = flush_callback


# =============================================================================
# Public API
# =============================================================================

## Add data to the buffer
func append(data: String) -> void:
	_buffer += data
	_total_bytes_buffered += data.length()
	_pending_flush = true

	# Force flush if buffer is too large
	if _buffer.length() > MAX_BUFFER_SIZE:
		flush_immediate()


## Process buffered output for this frame
## Returns the amount of data processed
func process_frame() -> int:
	if _buffer.is_empty():
		return 0

	var current_frame := Engine.get_process_frames()
	if current_frame == _last_flush_frame:
		return 0  # Already processed this frame

	_last_flush_frame = current_frame

	# Determine how much to process this frame
	var bytes_to_process := mini(_buffer.length(), MAX_BYTES_PER_FRAME)

	# Extract chunk to process
	var chunk := _buffer.substr(0, bytes_to_process)
	_buffer = _buffer.substr(bytes_to_process)

	# Invoke callback with chunk
	if _callback.is_valid():
		_callback.call(chunk)

	_pending_flush = not _buffer.is_empty()

	return bytes_to_process


## Force immediate flush of entire buffer
func flush_immediate() -> void:
	if _buffer.is_empty():
		return

	if _callback.is_valid():
		_callback.call(_buffer)

	_buffer = ""
	_pending_flush = false


## Check if there's pending data to flush
func has_pending() -> bool:
	return _pending_flush and not _buffer.is_empty()


## Get current buffer size
func get_buffer_size() -> int:
	return _buffer.length()


## Get total bytes buffered since creation
func get_total_bytes_buffered() -> int:
	return _total_bytes_buffered


## Clear the buffer without flushing
func clear() -> void:
	_buffer = ""
	_pending_flush = false


## Get buffer statistics
func get_stats() -> Dictionary:
	return {
		"buffer_size": _buffer.length(),
		"total_buffered": _total_bytes_buffered,
		"pending": _pending_flush
	}
