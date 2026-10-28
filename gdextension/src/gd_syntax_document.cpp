#include "gd_syntax_document.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cstdlib>
#include <cstring>

extern "C" const TSLanguage *tree_sitter_gdscript(void);

using namespace godot;

static inline bool is_utf8_continuation(unsigned char c) {
	return (c & 0xC0) == 0x80;
}

static std::string to_utf8(const String &p_text) {
	CharString cs = p_text.utf8();
	return std::string(cs.get_data(), cs.length());
}

GDSyntaxDocument::GDSyntaxDocument() {
	parser = ts_parser_new();
	ts_parser_set_language(parser, tree_sitter_gdscript());
	_reparse_full();
}

GDSyntaxDocument::~GDSyntaxDocument() {
	if (tree) {
		ts_tree_delete(tree);
	}
	ts_parser_delete(parser);
}

void GDSyntaxDocument::_reparse_full() {
	if (tree) {
		ts_tree_delete(tree);
	}
	tree = ts_parser_parse_string(parser, nullptr, src.data(), (uint32_t)src.size());
	last_changed_ranges.clear();
	version++;
}

TSPoint GDSyntaxDocument::_point_at(uint32_t p_byte) const {
	TSPoint p = { 0, 0 };
	uint32_t line_begin = 0;
	const uint32_t n = std::min<uint32_t>(p_byte, (uint32_t)src.size());
	for (uint32_t i = 0; i < n; i++) {
		if (src[i] == '\n') {
			p.row++;
			line_begin = i + 1;
		}
	}
	p.column = n - line_begin;
	return p;
}

uint32_t GDSyntaxDocument::_clamp_to_char_start(int64_t p_byte) const {
	int64_t b = std::clamp<int64_t>(p_byte, 0, (int64_t)src.size());
	while (b > 0 && b < (int64_t)src.size() && is_utf8_continuation((unsigned char)src[b])) {
		b--;
	}
	return (uint32_t)b;
}

// ---------------------------------------------------------------------------
// Source / file I/O

Error GDSyntaxDocument::load_file(const String &p_path) {
	Ref<FileAccess> f = FileAccess::open(p_path, FileAccess::READ);
	if (f.is_null()) {
		return FileAccess::get_open_error();
	}
	PackedByteArray bytes = f->get_buffer(f->get_length());
	path = p_path;
	set_source_bytes(bytes);
	return OK;
}

Error GDSyntaxDocument::save_file(const String &p_path) {
	const String target = p_path.is_empty() ? path : p_path;
	ERR_FAIL_COND_V_MSG(target.is_empty(), ERR_FILE_BAD_PATH, "GDSyntaxDocument has no path to save to.");
	Ref<FileAccess> f = FileAccess::open(target, FileAccess::WRITE);
	if (f.is_null()) {
		return FileAccess::get_open_error();
	}
	f->store_buffer(get_source_bytes());
	f->close();
	return OK;
}

void GDSyntaxDocument::set_source(const String &p_text) {
	src = to_utf8(p_text);
	_reparse_full();
}

void GDSyntaxDocument::set_source_bytes(const PackedByteArray &p_bytes) {
	src.assign((const char *)p_bytes.ptr(), (size_t)p_bytes.size());
	_reparse_full();
}

String GDSyntaxDocument::get_source() const {
	return String::utf8(src.data(), (int64_t)src.size());
}

PackedByteArray GDSyntaxDocument::get_source_bytes() const {
	PackedByteArray out;
	out.resize((int64_t)src.size());
	if (!src.empty()) {
		memcpy(out.ptrw(), src.data(), src.size());
	}
	return out;
}

int64_t GDSyntaxDocument::get_byte_length() const {
	return (int64_t)src.size();
}

String GDSyntaxDocument::get_path() const {
	return path;
}

void GDSyntaxDocument::set_path(const String &p_path) {
	path = p_path;
}

int64_t GDSyntaxDocument::get_version() const {
	return version;
}

// ---------------------------------------------------------------------------
// Text helpers

String GDSyntaxDocument::get_text(int64_t p_start, int64_t p_end) const {
	const uint32_t s = _clamp_to_char_start(p_start);
	const uint32_t e = std::max(s, _clamp_to_char_start(p_end));
	return String::utf8(src.data() + s, (int64_t)(e - s));
}

int64_t GDSyntaxDocument::byte_to_char(int64_t p_byte) const {
	const int64_t n = std::clamp<int64_t>(p_byte, 0, (int64_t)src.size());
	int64_t chars = 0;
	for (int64_t i = 0; i < n; i++) {
		if (!is_utf8_continuation((unsigned char)src[i])) {
			chars++;
		}
	}
	return chars;
}

int64_t GDSyntaxDocument::char_to_byte(int64_t p_char) const {
	int64_t chars = 0;
	for (int64_t i = 0; i < (int64_t)src.size(); i++) {
		if (!is_utf8_continuation((unsigned char)src[i])) {
			if (chars == p_char) {
				return i;
			}
			chars++;
		}
	}
	return (int64_t)src.size();
}

int64_t GDSyntaxDocument::line_start(int64_t p_byte) const {
	int64_t b = std::clamp<int64_t>(p_byte, 0, (int64_t)src.size());
	while (b > 0 && src[b - 1] != '\n') {
		b--;
	}
	return b;
}

int64_t GDSyntaxDocument::line_end(int64_t p_byte) const {
	int64_t b = std::clamp<int64_t>(p_byte, 0, (int64_t)src.size());
	while (b < (int64_t)src.size() && src[b] != '\n') {
		b++;
	}
	return b;
}

String GDSyntaxDocument::line_indent(int64_t p_byte) const {
	const int64_t s = line_start(p_byte);
	int64_t e = s;
	while (e < (int64_t)src.size() && (src[e] == ' ' || src[e] == '\t')) {
		e++;
	}
	return String::utf8(src.data() + s, e - s);
}

int64_t GDSyntaxDocument::row_of(int64_t p_byte) const {
	return _point_at((uint32_t)std::clamp<int64_t>(p_byte, 0, (int64_t)src.size())).row;
}

// ---------------------------------------------------------------------------
// Editing

bool GDSyntaxDocument::apply_edit(int64_t p_start, int64_t p_end, const String &p_text) {
	Dictionary e;
	e["start"] = p_start;
	e["end"] = p_end;
	e["text"] = p_text;
	Array edits;
	edits.push_back(e);
	return apply_edits(edits);
}

struct PendingEdit {
	uint32_t start;
	uint32_t end;
	std::string text;
};

bool GDSyntaxDocument::apply_edits(const Array &p_edits) {
	std::vector<PendingEdit> edits;
	edits.reserve(p_edits.size());
	for (int64_t i = 0; i < p_edits.size(); i++) {
		const Dictionary d = p_edits[i];
		ERR_FAIL_COND_V_MSG(!d.has("start") || !d.has("end"), false, "Edit needs 'start' and 'end'.");
		const int64_t s = d["start"];
		const int64_t e = d["end"];
		ERR_FAIL_COND_V_MSG(s < 0 || e < s || e > (int64_t)src.size(), false,
				vformat("Edit range [%d, %d) is outside the %d-byte buffer.", s, e, (int64_t)src.size()));
		edits.push_back({ _clamp_to_char_start(s), _clamp_to_char_start(e), to_utf8(String(d.get("text", String()))) });
	}
	// Apply back to front so earlier offsets stay valid.
	std::stable_sort(edits.begin(), edits.end(), [](const PendingEdit &a, const PendingEdit &b) {
		return a.start > b.start;
	});
	for (size_t i = 1; i < edits.size(); i++) {
		// edits[i] starts before edits[i-1]; it must also end before it.
		ERR_FAIL_COND_V_MSG(edits[i].end > edits[i - 1].start, false, "Edits overlap.");
	}
	if (edits.empty()) {
		return true;
	}

	TSTree *old_tree = ts_tree_copy(tree);
	for (const PendingEdit &pe : edits) {
		TSInputEdit ie;
		ie.start_byte = pe.start;
		ie.old_end_byte = pe.end;
		ie.new_end_byte = pe.start + (uint32_t)pe.text.size();
		ie.start_point = _point_at(pe.start);
		ie.old_end_point = _point_at(pe.end);
		TSPoint np = ie.start_point;
		for (char c : pe.text) {
			if (c == '\n') {
				np.row++;
				np.column = 0;
			} else {
				np.column++;
			}
		}
		ie.new_end_point = np;
		ts_tree_edit(tree, &ie);
		ts_tree_edit(old_tree, &ie);
		src.replace(pe.start, pe.end - pe.start, pe.text);
	}

	TSTree *new_tree = ts_parser_parse_string(parser, tree, src.data(), (uint32_t)src.size());
	last_changed_ranges.clear();
	uint32_t count = 0;
	TSRange *ranges = ts_tree_get_changed_ranges(old_tree, new_tree, &count);
	for (uint32_t i = 0; i < count; i++) {
		Dictionary r;
		r["start"] = (int64_t)ranges[i].start_byte;
		r["end"] = (int64_t)ranges[i].end_byte;
		last_changed_ranges.push_back(r);
	}
	::free(ranges);
	ts_tree_delete(old_tree);
	ts_tree_delete(tree);
	tree = new_tree;
	version++;
	return true;
}

Array GDSyntaxDocument::get_changed_ranges() const {
	return last_changed_ranges.duplicate(true);
}

// ---------------------------------------------------------------------------
// Tree access

Dictionary GDSyntaxDocument::_node_shallow(TSNode p_node) const {
	Dictionary d;
	d["type"] = String(ts_node_type(p_node));
	d["named"] = ts_node_is_named(p_node);
	d["start"] = (int64_t)ts_node_start_byte(p_node);
	d["end"] = (int64_t)ts_node_end_byte(p_node);
	const TSPoint sp = ts_node_start_point(p_node);
	const TSPoint ep = ts_node_end_point(p_node);
	d["row"] = (int64_t)sp.row;
	d["col"] = (int64_t)sp.column;
	d["end_row"] = (int64_t)ep.row;
	d["end_col"] = (int64_t)ep.column;
	if (ts_node_is_error(p_node) || ts_node_is_missing(p_node)) {
		d["error"] = true;
	}
	if (ts_node_has_error(p_node)) {
		d["has_error"] = true;
	}
	if (ts_node_is_extra(p_node)) {
		d["extra"] = true;
	}
	return d;
}

Dictionary GDSyntaxDocument::_node_to_dict(TSTreeCursor *p_cursor, bool p_include_anonymous) const {
	const TSNode node = ts_tree_cursor_current_node(p_cursor);
	Dictionary d = _node_shallow(node);
	Array children;
	if (ts_tree_cursor_goto_first_child(p_cursor)) {
		do {
			const TSNode child = ts_tree_cursor_current_node(p_cursor);
			const char *field = ts_tree_cursor_current_field_name(p_cursor);
			// Anonymous tokens are only interesting when a field names them (e.g. an operator).
			if (!p_include_anonymous && !ts_node_is_named(child) && field == nullptr) {
				continue;
			}
			Dictionary cd = _node_to_dict(p_cursor, p_include_anonymous);
			if (field) {
				cd["field"] = String(field);
			}
			children.push_back(cd);
		} while (ts_tree_cursor_goto_next_sibling(p_cursor));
		ts_tree_cursor_goto_parent(p_cursor);
	}
	d["children"] = children;
	return d;
}

Dictionary GDSyntaxDocument::get_tree(bool p_include_anonymous) const {
	TSTreeCursor cursor = ts_tree_cursor_new(ts_tree_root_node(tree));
	Dictionary d = _node_to_dict(&cursor, p_include_anonymous);
	ts_tree_cursor_delete(&cursor);
	return d;
}

Dictionary GDSyntaxDocument::named_node_at(int64_t p_start, int64_t p_end) const {
	const TSNode root = ts_tree_root_node(tree);
	const TSNode n = ts_node_named_descendant_for_byte_range(root, (uint32_t)std::max<int64_t>(0, p_start), (uint32_t)std::max<int64_t>(0, p_end));
	if (ts_node_is_null(n)) {
		return Dictionary();
	}
	return _node_shallow(n);
}

bool GDSyntaxDocument::has_errors() const {
	return ts_node_has_error(ts_tree_root_node(tree));
}

void GDSyntaxDocument::_collect_errors(TSNode p_node, Array &r_out) const {
	if (ts_node_is_error(p_node) || ts_node_is_missing(p_node)) {
		r_out.push_back(_node_shallow(p_node));
		return;
	}
	if (!ts_node_has_error(p_node)) {
		return;
	}
	const uint32_t n = ts_node_child_count(p_node);
	for (uint32_t i = 0; i < n; i++) {
		_collect_errors(ts_node_child(p_node, i), r_out);
	}
}

Array GDSyntaxDocument::get_errors() const {
	Array out;
	_collect_errors(ts_tree_root_node(tree), out);
	return out;
}

String GDSyntaxDocument::get_sexp() const {
	char *s = ts_node_string(ts_tree_root_node(tree));
	String out(s);
	::free(s);
	return out;
}

bool GDSyntaxDocument::_trees_equal(TSNode a, TSNode b) {
	if (ts_node_symbol(a) != ts_node_symbol(b) ||
			ts_node_start_byte(a) != ts_node_start_byte(b) ||
			ts_node_end_byte(a) != ts_node_end_byte(b) ||
			ts_node_is_missing(a) != ts_node_is_missing(b)) {
		return false;
	}
	const uint32_t n = ts_node_child_count(a);
	if (n != ts_node_child_count(b)) {
		return false;
	}
	for (uint32_t i = 0; i < n; i++) {
		if (!_trees_equal(ts_node_child(a, i), ts_node_child(b, i))) {
			return false;
		}
	}
	return true;
}

// Re-parses the buffer from scratch and checks that the incrementally
// maintained tree is identical (symbols, byte ranges, shape).
bool GDSyntaxDocument::verify_incremental() const {
	TSParser *p = ts_parser_new();
	ts_parser_set_language(p, tree_sitter_gdscript());
	TSTree *fresh = ts_parser_parse_string(p, nullptr, src.data(), (uint32_t)src.size());
	const bool equal = _trees_equal(ts_tree_root_node(tree), ts_tree_root_node(fresh));
	ts_tree_delete(fresh);
	ts_parser_delete(p);
	return equal;
}

// ---------------------------------------------------------------------------

void GDSyntaxDocument::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_file", "path"), &GDSyntaxDocument::load_file);
	ClassDB::bind_method(D_METHOD("save_file", "path"), &GDSyntaxDocument::save_file, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("set_source", "text"), &GDSyntaxDocument::set_source);
	ClassDB::bind_method(D_METHOD("set_source_bytes", "bytes"), &GDSyntaxDocument::set_source_bytes);
	ClassDB::bind_method(D_METHOD("get_source"), &GDSyntaxDocument::get_source);
	ClassDB::bind_method(D_METHOD("get_source_bytes"), &GDSyntaxDocument::get_source_bytes);
	ClassDB::bind_method(D_METHOD("get_byte_length"), &GDSyntaxDocument::get_byte_length);
	ClassDB::bind_method(D_METHOD("get_path"), &GDSyntaxDocument::get_path);
	ClassDB::bind_method(D_METHOD("set_path", "path"), &GDSyntaxDocument::set_path);
	ClassDB::bind_method(D_METHOD("get_version"), &GDSyntaxDocument::get_version);

	ClassDB::bind_method(D_METHOD("get_text", "start", "end"), &GDSyntaxDocument::get_text);
	ClassDB::bind_method(D_METHOD("byte_to_char", "byte"), &GDSyntaxDocument::byte_to_char);
	ClassDB::bind_method(D_METHOD("char_to_byte", "char"), &GDSyntaxDocument::char_to_byte);
	ClassDB::bind_method(D_METHOD("line_start", "byte"), &GDSyntaxDocument::line_start);
	ClassDB::bind_method(D_METHOD("line_end", "byte"), &GDSyntaxDocument::line_end);
	ClassDB::bind_method(D_METHOD("line_indent", "byte"), &GDSyntaxDocument::line_indent);
	ClassDB::bind_method(D_METHOD("row_of", "byte"), &GDSyntaxDocument::row_of);

	ClassDB::bind_method(D_METHOD("apply_edit", "start", "end", "text"), &GDSyntaxDocument::apply_edit);
	ClassDB::bind_method(D_METHOD("apply_edits", "edits"), &GDSyntaxDocument::apply_edits);
	ClassDB::bind_method(D_METHOD("get_changed_ranges"), &GDSyntaxDocument::get_changed_ranges);

	ClassDB::bind_method(D_METHOD("get_tree", "include_anonymous"), &GDSyntaxDocument::get_tree, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("named_node_at", "start", "end"), &GDSyntaxDocument::named_node_at);
	ClassDB::bind_method(D_METHOD("has_errors"), &GDSyntaxDocument::has_errors);
	ClassDB::bind_method(D_METHOD("get_errors"), &GDSyntaxDocument::get_errors);
	ClassDB::bind_method(D_METHOD("get_sexp"), &GDSyntaxDocument::get_sexp);
	ClassDB::bind_method(D_METHOD("verify_incremental"), &GDSyntaxDocument::verify_incremental);
}
