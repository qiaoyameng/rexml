# frozen_string_literal: false

module REXML
  # \REXML::Writer is a streaming, IO-oriented XML writer.
  #
  # It writes a document node by node directly to a caller supplied IO-like
  # object (anything responding to +write+), without building a tree in
  # memory.  Working memory grows only with the element nesting depth and
  # the currently open start tag.
  #
  # == Example
  #
  #   writer = REXML::Writer.new(io)
  #   writer.start_element("{http://example.com}root")
  #   writer.attribute("version", "1.0")
  #   writer.start_element("child")
  #   writer.text("content")
  #   writer.end_element
  #   writer.end_element
  #   writer.finish
  #
  # == Names
  #
  # Element and attribute names may be given as:
  #
  # - a plain name: +"title"+
  # - a qualified name: +"prefix:title"+ (the prefix must be bound in scope)
  # - an expanded name in Clark notation: +"{http://uri}title"+; the writer
  #   reuses an in-scope prefix bound to the URI, or generates and declares
  #   a new prefix on the current element.
  #
  # Namespace declarations are written with the attributes +"xmlns"+ and
  # +"xmlns:prefix"+ and are scoped to the current element.
  #
  # == Error handling
  #
  # Misuse (attributes after content, duplicate attributes, unbound
  # prefixes, invalid characters, unclosed elements, and so on) raises
  # REXML::Writer::Error.  If the underlying IO raises or performs a short
  # write, the writer enters a broken state and every subsequent call
  # raises REXML::Writer::Error.  The caller's IO is never closed by the
  # writer.
  class Writer
    # Raised on any writer misuse or after an underlying IO failure.
    class Error < StandardError
    end

    XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"
    XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/"

    INVALID_CHARACTERS = /[^\x09\x0A\x0D\x20-\u{D7FF}\u{E000}-\u{FFFD}\u{10000}-\u{10FFFF}]/
    NCNAME = /\A[\p{L}_][\p{L}\p{N}._-]*\z/

    TEXT_ESCAPES = {
      "&" => "&amp;",
      "<" => "&lt;",
      ">" => "&gt;",
      "\r" => "&#13;",
    }.freeze
    TEXT_ESCAPES_PATTERN = /[&<>\r]/

    ATTRIBUTE_ESCAPES = {
      "&" => "&amp;",
      "<" => "&lt;",
      '"' => "&quot;",
      "\t" => "&#9;",
      "\n" => "&#10;",
      "\r" => "&#13;",
    }.freeze
    ATTRIBUTE_ESCAPES_PATTERN = /[&<"\t\n\r]/

    # +io+ is any object responding to +write(string)+ and returning the
    # number of bytes written, such as IO or StringIO.  The writer never
    # closes +io+; ownership stays with the caller.
    def initialize(io)
      @io = io
      @stack = []          # open elements: [[qname, [uri, local]], ...]
      @scopes = []         # per-element namespace declarations: {prefix => uri}
      @pending = nil       # open start tag: {qname:, buffer:, seen:}
      @root_count = 0
      @prefix_counter = 0
      @broken = false
      @finished = false
    end

    # Whether the writer is broken after an underlying IO failure.
    def broken?
      @broken
    end

    # Whether #finish has completed successfully.
    def finished?
      @finished
    end

    # Starts an element.  See the class documentation for the accepted
    # name forms.  The start tag is held open until the first content so
    # that attributes can still be added.
    def start_element(name)
      ensure_usable
      if @stack.empty? and @root_count > 0
        raise Error, "document already has a root element"
      end
      flush_pending
      @scopes.push({})
      @pending = {buffer: +"", seen: {}}
      begin
        qname, expanded = resolve_element_name(name)
      rescue Exception
        @scopes.pop
        @pending = nil
        raise
      end
      @pending[:qname] = qname
      @pending[:buffer] = "<#{qname}#{@pending[:buffer]}"
      @stack.push([qname, expanded])
      @root_count += 1 if @stack.size == 1
      nil
    end

    # Adds an attribute to the currently open start tag.  Raises if no
    # start tag is open (for example after content has been written) or
    # if an attribute with the same expanded name was already added,
    # regardless of the prefixes used.
    #
    # The names +"xmlns"+ and +"xmlns:prefix"+ declare a namespace for the
    # scope of the current element instead of adding a regular attribute.
    def attribute(name, value)
      ensure_usable
      unless @pending
        raise Error, "attributes must be added before any content of the element"
      end
      value = value.to_s
      check_characters(value)
      prefix, local, uri = split_name(name)
      if uri.nil? and prefix.nil? and local == "xmlns"
        declare_namespace("", value)
        return nil
      end
      if uri.nil? and prefix == "xmlns"
        validate_ncname(local, "prefix")
        declare_namespace(local, value)
        return nil
      end
      if uri
        validate_ncname(local)
        check_uri(uri)
        bound = find_prefix_for(uri, false) || generate_prefix(uri)
        qname = "#{bound}:#{local}"
        expanded = [uri, local]
      elsif prefix
        validate_ncname(prefix, "prefix")
        validate_ncname(local)
        resolved = lookup_prefix(prefix)
        raise Error, "unbound prefix #{prefix.inspect}" unless resolved
        qname = "#{prefix}:#{local}"
        expanded = [resolved, local]
      else
        validate_ncname(local)
        qname = local
        expanded = [nil, local]
      end
      if @pending[:seen].key?(expanded)
        raise Error, "duplicate attribute #{qname.inspect}"
      end
      @pending[:seen][expanded] = true
      @pending[:buffer] << " " << qname << '="' << escape_attribute(value) << '"'
      nil
    end

    # Writes escaped character data.  Only whitespace is allowed outside
    # the root element.
    def text(string)
      ensure_usable
      string = string.to_s
      check_characters(string)
      if @stack.empty? and string !~ /\A[ \t\r\n]*\z/
        raise Error, "text is not allowed outside the root element"
      end
      flush_pending
      write_output(escape_text(string))
      nil
    end

    # Writes a CDATA section.  The content must not contain +]]>+ and is
    # only allowed inside the root element.
    def cdata(string)
      ensure_usable
      string = string.to_s
      check_characters(string)
      if @stack.empty?
        raise Error, "CDATA sections are not allowed outside the root element"
      end
      if string.include?("]]>")
        raise Error, "CDATA content must not contain ']]>'"
      end
      flush_pending
      write_output("<![CDATA[#{string}]]>")
      nil
    end

    # Writes a comment.  The content must not contain +--+ and must not
    # end with +-+.
    def comment(string)
      ensure_usable
      string = string.to_s
      check_characters(string)
      if string.include?("--")
        raise Error, "comment content must not contain '--'"
      end
      if string.end_with?("-")
        raise Error, "comment content must not end with '-'"
      end
      flush_pending
      write_output("<!--#{string}-->")
      nil
    end

    # Ends the current element.  If +name+ is given, its expanded name
    # must match the open element.
    def end_element(name = nil)
      ensure_usable
      raise Error, "no open element" if @stack.empty?
      qname, expanded = @stack.last
      if name
        expected = expanded_name_for_check(name)
        unless expected == expanded
          raise Error, "end tag #{name.inspect} does not match open element #{qname.inspect}"
        end
      end
      if @pending
        write_output(@pending[:buffer] + "/>")
        @pending = nil
      else
        write_output("</#{qname}>")
      end
      @stack.pop
      @scopes.pop
      nil
    end

    # Finishes the document.  Raises unless exactly one root element was
    # written and all elements are closed; nothing is invented or
    # auto-closed.  The underlying IO is left open.
    def finish
      ensure_usable
      unless @stack.empty?
        open = @stack.map {|qname, _| qname }.join(", ")
        raise Error, "unclosed element(s): #{open}"
      end
      raise Error, "document has no root element" if @root_count.zero?
      @finished = true
      nil
    end

    private

    def ensure_usable
      if @broken
        raise Error, "writer is broken after an underlying IO failure"
      end
      raise Error, "writer is already finished" if @finished
    end

    def flush_pending
      return unless @pending
      write_output(@pending[:buffer] + ">")
      @pending = nil
    end

    def write_output(string)
      return if string.empty?
      begin
        written = @io.write(string)
      rescue Exception
        @broken = true
        raise
      end
      unless written == string.bytesize
        @broken = true
        raise Error, "short write: expected #{string.bytesize} bytes, wrote #{written.inspect}"
      end
    end

    # Splits +name+ into [prefix, local, uri].  Exactly one of +prefix+
    # or +uri+ is set; both are nil for a plain local name.
    def split_name(name)
      name = name.to_s
      if name.start_with?("{")
        close = name.index("}")
        unless close
          raise Error, "malformed expanded name #{name.inspect}"
        end
        uri = name[1...close]
        local = name[(close + 1)..]
        if local.empty?
          raise Error, "malformed expanded name #{name.inspect}"
        end
        [nil, local, uri.empty? ? nil : uri]
      elsif name.include?(":")
        prefix, local = name.split(":", 2)
        [prefix, local, nil]
      else
        [nil, name, nil]
      end
    end

    def resolve_element_name(name)
      prefix, local, uri = split_name(name)
      validate_ncname(local)
      if uri
        check_uri(uri)
        bound = find_prefix_for(uri, true) || generate_prefix(uri)
        qname = bound.empty? ? local : "#{bound}:#{local}"
        [qname, [uri, local]]
      elsif prefix
        validate_ncname(prefix, "prefix")
        resolved = lookup_prefix(prefix)
        raise Error, "unbound prefix #{prefix.inspect}" unless resolved
        ["#{prefix}:#{local}", [resolved, local]]
      else
        [local, [lookup_prefix(""), local]]
      end
    end

    # Resolves +name+ (given to #end_element) to an expanded name using
    # the currently in-scope declarations.
    def expanded_name_for_check(name)
      prefix, local, uri = split_name(name)
      if uri
        [uri, local]
      elsif prefix
        resolved = lookup_prefix(prefix)
        raise Error, "unbound prefix #{prefix.inspect}" unless resolved
        [resolved, local]
      else
        [lookup_prefix(""), local]
      end
    end

    def lookup_prefix(prefix)
      return XML_NAMESPACE if prefix == "xml"
      return nil if prefix == "xmlns"
      @scopes.reverse_each do |scope|
        return scope[prefix] if scope.key?(prefix)
      end
      nil
    end

    def find_prefix_for(uri, allow_default)
      return "xml" if uri == XML_NAMESPACE
      @scopes.reverse_each do |scope|
        scope.each do |prefix, bound|
          next if prefix.empty? and not allow_default
          return prefix if bound == uri
        end
      end
      nil
    end

    # Generates a fresh prefix for +uri+, records the declaration in the
    # innermost scope, and appends it to the pending start tag.
    def generate_prefix(uri)
      loop do
        @prefix_counter += 1
        prefix = "ns#{@prefix_counter}"
        next if lookup_prefix(prefix)
        @scopes.last[prefix] = uri
        @pending[:buffer] << " xmlns:#{prefix}" << '="' << escape_attribute(uri) << '"'
        return prefix
      end
    end

    def declare_namespace(prefix, uri)
      scope = @scopes.last
      if scope.key?(prefix)
        raise Error, "duplicate namespace declaration for prefix #{prefix.inspect}"
      end
      validate_prefix_binding(prefix, uri)
      scope[prefix] = uri
      declaration = prefix.empty? ? "xmlns" : "xmlns:#{prefix}"
      @pending[:buffer] << " " << declaration << '="' << escape_attribute(uri) << '"'
      nil
    end

    def validate_prefix_binding(prefix, uri)
      check_uri(uri) unless uri.empty?
      if prefix == "xml"
        unless uri == XML_NAMESPACE
          raise Error, "prefix 'xml' must be bound to #{XML_NAMESPACE.inspect}"
        end
      elsif prefix == "xmlns"
        raise Error, "prefix 'xmlns' must not be declared"
      elsif prefix =~ /\Axml/i
        raise Error, "prefixes beginning with 'xml' are reserved"
      end
      if uri == XMLNS_NAMESPACE
        raise Error, "namespace #{XMLNS_NAMESPACE.inspect} must not be declared"
      end
      if uri == XML_NAMESPACE and prefix != "xml"
        raise Error, "namespace #{XML_NAMESPACE.inspect} must be bound to 'xml'"
      end
      if uri.empty? and not prefix.empty?
        raise Error, "prefixed namespace #{prefix.inspect} must not be undeclared"
      end
    end

    def validate_ncname(name, what = "name")
      unless NCNAME.match?(name)
        raise Error, "invalid #{what} #{name.inspect}"
      end
    end

    def check_uri(uri)
      check_characters(uri)
      if uri =~ /\s/
        raise Error, "namespace URI must not contain whitespace"
      end
    end

    def check_characters(string)
      unless string.valid_encoding?
        raise Error, "invalid byte sequence for #{string.encoding}"
      end
      begin
        match = INVALID_CHARACTERS.match(string)
      rescue Encoding::CompatibilityError
        raise Error, "unsupported string encoding #{string.encoding}"
      end
      if match
        raise Error, format("invalid XML character U+%04X", match[0].ord)
      end
    end

    def escape_text(string)
      string.gsub(TEXT_ESCAPES_PATTERN, TEXT_ESCAPES)
    end

    def escape_attribute(string)
      string.gsub(ATTRIBUTE_ESCAPES_PATTERN, ATTRIBUTE_ESCAPES)
    end
  end
end
