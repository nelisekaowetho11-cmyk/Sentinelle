package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// A deliberately small TOML reader: sections, scalars and string arrays.
// Keeping it in-tree means the binary builds on an air-gapped box with
// nothing but a Go toolchain.

type tomlDoc map[string]map[string]string

// arrays are stored separately, keyed "section.key"
type tomlFile struct {
	scalars tomlDoc
	arrays  map[string][]string
}

func parseTOML(path string) (*tomlFile, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	tf := &tomlFile{scalars: tomlDoc{}, arrays: map[string][]string{}}
	section := ""
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := stripComment(sc.Text())
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			if _, ok := tf.scalars[section]; !ok {
				tf.scalars[section] = map[string]string{}
			}
			continue
		}

		eq := strings.Index(line, "=")
		if eq < 0 {
			return nil, fmt.Errorf("%s:%d: expected key = value, got %q", path, lineNo, line)
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])

		if strings.HasPrefix(val, "[") {
			// array, possibly spanning several lines
			body := val
			for !strings.Contains(body, "]") {
				if !sc.Scan() {
					return nil, fmt.Errorf("%s:%d: unterminated array for key %q", path, lineNo, key)
				}
				lineNo++
				body += " " + strings.TrimSpace(stripComment(sc.Text()))
			}
			items, err := parseArray(body)
			if err != nil {
				return nil, fmt.Errorf("%s:%d: %v", path, lineNo, err)
			}
			tf.arrays[section+"."+key] = items
			continue
		}

		if tf.scalars[section] == nil {
			tf.scalars[section] = map[string]string{}
		}
		tf.scalars[section][key] = unquote(val)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return tf, nil
}

func stripComment(s string) string {
	inQuote := false
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"':
			inQuote = !inQuote
		case '#':
			if !inQuote {
				return s[:i]
			}
		}
	}
	return s
}

func parseArray(s string) ([]string, error) {
	open := strings.Index(s, "[")
	close := strings.LastIndex(s, "]")
	if open < 0 || close < open {
		return nil, fmt.Errorf("malformed array %q", s)
	}
	inner := s[open+1 : close]
	var out []string
	for _, part := range strings.Split(inner, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		out = append(out, unquote(part))
	}
	return out, nil
}

func unquote(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'') {
			return s[1 : len(s)-1]
		}
	}
	return s
}

func (t *tomlFile) str(section, key, def string) string {
	if m, ok := t.scalars[section]; ok {
		if v, ok := m[key]; ok && v != "" {
			return v
		}
	}
	return def
}

func (t *tomlFile) has(section, key string) bool {
	if m, ok := t.scalars[section]; ok {
		_, ok := m[key]
		return ok
	}
	return false
}

func (t *tomlFile) hasSection(section string) bool {
	_, ok := t.scalars[section]
	if ok {
		return true
	}
	for k := range t.arrays {
		if strings.HasPrefix(k, section+".") {
			return true
		}
	}
	return false
}

func (t *tomlFile) int(section, key string, def int) (int, error) {
	raw := t.str(section, key, "")
	if raw == "" {
		return def, nil
	}
	// TOML permits digit separators: channel_size = 10_000
	raw = strings.ReplaceAll(raw, "_", "")
	n, err := strconv.Atoi(raw)
	if err != nil {
		return def, fmt.Errorf("[%s] %s: %q is not a number", section, key, raw)
	}
	return n, nil
}

func (t *tomlFile) bool_(section, key string, def bool) (bool, error) {
	raw := strings.ToLower(t.str(section, key, ""))
	if raw == "" {
		return def, nil
	}
	switch raw {
	case "true", "yes", "1", "on":
		return true, nil
	case "false", "no", "0", "off":
		return false, nil
	}
	return def, fmt.Errorf("[%s] %s: %q is not a boolean", section, key, raw)
}

func (t *tomlFile) list(section, key string) []string {
	return t.arrays[section+"."+key]
}
