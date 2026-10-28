#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <string>
#include <vector>

#include <tree_sitter/api.h>

namespace godot {

// One GDScript source file held as raw UTF-8 bytes plus its tree-sitter CST.
//
// All positions exposed to scripts are *byte* offsets into the UTF-8 buffer,
// exactly as tree-sitter reports them. The buffer is never re-encoded, so a
// file loaded and saved without edits is byte-identical (line endings, BOM and
// all). Every modification goes through apply_edit()/apply_edits(), which
// splice the buffer, tell tree-sitter about the edit and re-parse incrementally.
class GDSyntaxDocument : public RefCounted {
	GDCLASS(GDSyntaxDocument, RefCounted)

	TSParser *parser = nullptr;
	TSTree *tree = nullptr;
	std::string src;
	String path;
	int64_t version = 0;
	Array last_changed_ranges;

	void _reparse_full();
	TSPoint _point_at(uint32_t p_byte) const;
	uint32_t _clamp_to_char_start(int64_t p_byte) const;
	Dictionary _node_to_dict(TSTreeCursor *p_cursor, bool p_include_anonymous) const;
	Dictionary _node_shallow(TSNode p_node) const;
	void _collect_errors(TSNode p_node, Array &r_out) const;
	static bool _trees_equal(TSNode a, TSNode b);

protected:
	static void _bind_methods();

public:
	// Source / file I/O.
	Error load_file(const String &p_path);
	Error save_file(const String &p_path = String());
	void set_source(const String &p_text);
	void set_source_bytes(const PackedByteArray &p_bytes);
	String get_source() const;
	PackedByteArray get_source_bytes() const;
	int64_t get_byte_length() const;
	String get_path() const;
	void set_path(const String &p_path);
	int64_t get_version() const;

	// Byte-range text access and conversion helpers.
	String get_text(int64_t p_start, int64_t p_end) const;
	int64_t byte_to_char(int64_t p_byte) const;
	int64_t char_to_byte(int64_t p_char) const;
	int64_t line_start(int64_t p_byte) const;
	int64_t line_end(int64_t p_byte) const;
	String line_indent(int64_t p_byte) const;
	int64_t row_of(int64_t p_byte) const;

	// Editing. Edits are {start, end, text} dictionaries in byte offsets of the
	// *current* buffer; they must not overlap and are applied atomically.
	bool apply_edit(int64_t p_start, int64_t p_end, const String &p_text);
	bool apply_edits(const Array &p_edits);
	Array get_changed_ranges() const;

	// Tree access.
	Dictionary get_tree(bool p_include_anonymous = true) const;
	Dictionary named_node_at(int64_t p_start, int64_t p_end) const;
	bool has_errors() const;
	Array get_errors() const;
	String get_sexp() const;
	bool verify_incremental() const;

	GDSyntaxDocument();
	~GDSyntaxDocument();
};

} // namespace godot
