#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <moonbit.h>

#include "md4c.h"

// The result starts with one status byte, then one record per link or image: a kind byte ('A' or 'I'), the destination's length as 4 little-endian bytes, and the destination.
enum { STATUS_OK = 0, STATUS_PARSE_FAILED = 1, STATUS_NO_MEMORY = 2 };

struct records {
  unsigned char *data;
  size_t length;
  size_t capacity;
  int failed;
};

static void append(struct records *out, const void *bytes, size_t size) {
  if (out->failed || size == 0)
    return;
  if (out->length + size > out->capacity) {
    size_t capacity = out->capacity == 0 ? 256 : out->capacity;
    while (capacity < out->length + size)
      capacity *= 2;
    unsigned char *grown = realloc(out->data, capacity);
    if (grown == NULL) {
      out->failed = 1;
      return;
    }
    out->data = grown;
    out->capacity = capacity;
  }
  memcpy(out->data + out->length, bytes, size);
  out->length += size;
}

static void record(struct records *out, unsigned char kind, const MD_ATTRIBUTE *attribute) {
  unsigned char head[5] = {
    kind,
    (unsigned char)(attribute->size & 0xff),
    (unsigned char)((attribute->size >> 8) & 0xff),
    (unsigned char)((attribute->size >> 16) & 0xff),
    (unsigned char)((attribute->size >> 24) & 0xff),
  };
  append(out, head, sizeof head);
  append(out, attribute->text, attribute->size);
}

static int enter_span(MD_SPANTYPE type, void *detail, void *userdata) {
  struct records *out = userdata;
  if (type == MD_SPAN_A)
    record(out, 'A', &((MD_SPAN_A_DETAIL *)detail)->href);
  else if (type == MD_SPAN_IMG)
    record(out, 'I', &((MD_SPAN_IMG_DETAIL *)detail)->src);
  return out->failed ? -1 : 0;
}

static int ignore_block(MD_BLOCKTYPE type, void *detail, void *userdata) { return 0; }
static int ignore_span(MD_SPANTYPE type, void *detail, void *userdata) { return 0; }
static int ignore_text(MD_TEXTTYPE type, const MD_CHAR *text, MD_SIZE size, void *userdata) { return 0; }

// Tables, strikethrough and task lists are what Bun.markdown.render reads by default.
// The two NO flags are what the templates turn on, because prompts wrap sections in tags and indent prose.
#define TEMPLATE_FLAGS (MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_TASKLISTS | MD_FLAG_NOHTMLBLOCKS | MD_FLAG_NOINDENTEDCODEBLOCKS)

static moonbit_bytes_t reply(unsigned char status, const struct records *out) {
  moonbit_bytes_t result = moonbit_make_bytes((int32_t)(1 + out->length), 0);
  result[0] = status;
  if (out->length > 0)
    memcpy(result + 1, out->data, out->length);
  return result;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t harnexus_md_destinations(moonbit_bytes_t text, int32_t size) {
  struct records out = {NULL, 0, 0, 0};
  MD_PARSER parser;
  memset(&parser, 0, sizeof parser);
  parser.abi_version = 0;
  parser.flags = TEMPLATE_FLAGS;
  parser.enter_block = ignore_block;
  parser.leave_block = ignore_block;
  parser.enter_span = enter_span;
  parser.leave_span = ignore_span;
  parser.text = ignore_text;
  int status = md_parse((const MD_CHAR *)text, (MD_SIZE)size, &parser, &out);
  struct records none = {NULL, 0, 0, 0};
  moonbit_bytes_t result;
  if (out.failed)
    result = reply(STATUS_NO_MEMORY, &none);
  else if (status != 0)
    result = reply(STATUS_PARSE_FAILED, &none);
  else
    result = reply(STATUS_OK, &out);
  free(out.data);
  return result;
}
