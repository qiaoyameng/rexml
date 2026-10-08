# frozen_string_literal: false

require "test/unit"
require "rexml/document"
require "stringio"

module REXMLTests
  class WriterTest < Test::Unit::TestCase
    # Records every chunk the writer emits so tests can verify that
    # output is streamed in small pieces instead of being buffered.
    class ChunkedSink
      attr_reader :chunks

      def initialize
        @chunks = []
      end

      def write(string)
        @chunks << string.dup
        string.bytesize
      end

      def content
        @chunks.join
      end

      def max_chunk_size
        @chunks.map(&:bytesize).max || 0
      end
    end

    class ShortWriteSink
      def initialize
        @closed_count = 0
      end

      def write(string)
        string.bytesize - 1
      end

      def close
        @closed_count += 1
      end

      def closed?
        @closed_count > 0
      end
    end

    class FailingSink
      def initialize
        @closed_count = 0
      end

      def write(string)
        raise IOError, "disk full"
      end

      def close
        @closed_count += 1
      end

      def closed?
        @closed_count > 0
      end
    end

    def write_document(&block)
      io = StringIO.new
      writer = REXML::Writer.new(io)
      block.call(writer)
      io.string
    end

    def canonical(node)
      case node
      when REXML::Element
        attributes = []
        node.attributes.each_attribute do |attribute|
          next if attribute.prefix == "xmlns" or attribute.name == "xmlns"
          attributes << [attribute.namespace, attribute.name, attribute.value]
        end
        [:element, node.namespace, node.name, attributes.sort,
         node.children.map {|child| canonical(child) }.compact]
      when REXML::CData
        [:cdata, node.value]
      when REXML::Comment
        [:comment, node.string]
      when REXML::Text
        [:text, node.value]
      end
    end

    def canonical_document(document)
      document.children.map {|child| canonical(child) }.compact
    end

    def test_simple_document
      xml = write_document do |writer|
        writer.start_element("root")
        writer.attribute("id", "1")
        writer.text("hello")
        writer.end_element
        writer.finish
      end
      assert_equal('<root id="1">hello</root>', xml)
    end

    def test_empty_element
      xml = write_document do |writer|
        writer.start_element("root")
        writer.start_element("empty")
        writer.end_element
        writer.end_element
        writer.finish
      end
      assert_equal("<root><empty/></root>", xml)
    end

    def test_text_escaping
      xml = write_document do |writer|
        writer.start_element("root")
        writer.text("a & b < c > d")
        writer.end_element
        writer.finish
      end
      assert_equal("<root>a &amp; b &lt; c &gt; d</root>", xml)
    end

    def test_attribute_escaping
      xml = write_document do |writer|
        writer.start_element("root")
        writer.attribute("a", "<&\"\t\n>")
        writer.end_element
        writer.finish
      end
      assert_equal(%Q{<root a="&lt;&amp;&quot;&#9;&#10;>"/>}, xml)
    end

    def test_cdata
      xml = write_document do |writer|
        writer.start_element("root")
        writer.cdata("a & <b> c")
        writer.end_element
        writer.finish
      end
      assert_equal("<root><![CDATA[a & <b> c]]></root>", xml)
    end

    def test_comment
      xml = write_document do |writer|
        writer.comment("prolog")
        writer.start_element("root")
        writer.comment("in-side")
        writer.end_element
        writer.finish
      end
      assert_equal("<!--prolog--><root><!--in-side--></root>", xml)
    end

    def test_expanded_name_generates_prefix
      xml = write_document do |writer|
        writer.start_element("{http://example.com/a}root")
        writer.attribute("{http://example.com/b}attr", "v")
        writer.end_element
        writer.finish
      end
      document = REXML::Document.new(xml)
      assert_equal("http://example.com/a", document.root.namespace)
      assert_equal("root", document.root.name)
      attribute = document.root.attributes.get_attribute_ns("http://example.com/b", "attr")
      assert_not_nil(attribute)
      assert_equal("v", attribute.value)
    end

    def test_expanded_name_reuses_in_scope_prefix
      xml = write_document do |writer|
        writer.start_element("root")
        writer.attribute("xmlns:ex", "http://example.com")
        writer.start_element("{http://example.com}child")
        writer.attribute("{http://example.com}attr", "1")
        writer.end_element
        writer.end_element
        writer.finish
      end
      assert_equal('<root xmlns:ex="http://example.com">' \
                   '<ex:child ex:attr="1"/></root>', xml)
    end

    def test_default_namespace
      xml = write_document do |writer|
        writer.start_element("root")
        writer.attribute("xmlns", "http://example.com/default")
        writer.start_element("child")
        writer.end_element
        writer.end_element
        writer.finish
      end
      assert_equal('<root xmlns="http://example.com/default"><child/></root>', xml)
      document = REXML::Document.new(xml)
      assert_equal("http://example.com/default", document.root.elements[1].namespace)
    end

    def test_end_element_with_matching_name
      xml = write_document do |writer|
        writer.start_element("root")
        writer.end_element("root")
        writer.finish
      end
      assert_equal("<root/>", xml)
    end

    def test_end_element_with_mismatched_name
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.end_element("other")
        end
      end
    end

    def test_end_element_without_open_element
      assert_raise(REXML::Writer::Error) do
        write_document {|writer| writer.end_element }
      end
    end

    def test_attribute_after_text
      error = assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.text("content")
          writer.attribute("late", "1")
        end
      end
      assert_match(/before any content/, error.message)
    end

    def test_attribute_after_child_element
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.start_element("child")
          writer.end_element
          writer.attribute("late", "1")
        end
      end
    end

    def test_attribute_without_open_element
      assert_raise(REXML::Writer::Error) do
        write_document {|writer| writer.attribute("a", "1") }
      end
    end

    def test_duplicate_attribute_same_name
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.attribute("a", "1")
          writer.attribute("a", "2")
        end
      end
    end

    def test_duplicate_attribute_via_different_prefixes
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.attribute("xmlns:a", "http://example.com")
          writer.attribute("xmlns:b", "http://example.com")
          writer.attribute("a:attr", "1")
          writer.attribute("b:attr", "2")
        end
      end
    end

    def test_duplicate_attribute_via_expanded_name
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.attribute("xmlns:a", "http://example.com")
          writer.attribute("a:attr", "1")
          writer.attribute("{http://example.com}attr", "2")
        end
      end
    end

    def test_same_local_name_in_different_namespaces_is_allowed
      xml = write_document do |writer|
        writer.start_element("root")
        writer.attribute("xmlns:a", "http://example.com/a")
        writer.attribute("xmlns:b", "http://example.com/b")
        writer.attribute("a:attr", "1")
        writer.attribute("b:attr", "2")
        writer.end_element
        writer.finish
      end
      document = REXML::Document.new(xml)
      assert_equal("1", document.root.attributes.get_attribute_ns("http://example.com/a", "attr").value)
      assert_equal("2", document.root.attributes.get_attribute_ns("http://example.com/b", "attr").value)
    end

    def test_unbound_prefix
      assert_raise(REXML::Writer::Error) do
        write_document {|writer| writer.start_element("p:root") }
      end
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.attribute("p:attr", "1")
        end
      end
    end

    def test_cdata_rejects_terminator
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.cdata("a ]]> b")
        end
      end
    end

    def test_comment_rejects_double_hyphen
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.comment("a -- b")
        end
      end
    end

    def test_comment_rejects_trailing_hyphen
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.comment("ends-")
        end
      end
    end

    def test_invalid_characters
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.text("bad\x0Bchar")
        end
      end
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.attribute("a", "bad\x00char")
        end
      end
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.cdata("bad\x0Cchar")
        end
      end
    end

    def test_text_outside_root
      assert_raise(REXML::Writer::Error) do
        write_document {|writer| writer.text("content") }
      end
    end

    def test_whitespace_text_outside_root_is_allowed
      xml = write_document do |writer|
        writer.text("  \n")
        writer.start_element("root")
        writer.end_element
        writer.text("\n")
        writer.finish
      end
      assert_equal("  \n<root/>\n", xml)
    end

    def test_cdata_outside_root
      assert_raise(REXML::Writer::Error) do
        write_document {|writer| writer.cdata("content") }
      end
    end

    def test_multiple_roots
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("one")
          writer.end_element
          writer.start_element("two")
        end
      end
    end

    def test_finish_with_unclosed_elements
      error = assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.start_element("root")
          writer.start_element("child")
          writer.finish
        end
      end
      assert_match(/unclosed/, error.message)
    end

    def test_finish_without_root
      assert_raise(REXML::Writer::Error) do
        write_document do |writer|
          writer.comment("only a comment")
          writer.finish
        end
      end
    end

    def test_calls_after_finish
      writer = REXML::Writer.new(StringIO.new)
      writer.start_element("root")
      writer.end_element
      writer.finish
      assert_raise(REXML::Writer::Error) { writer.start_element("again") }
      assert_raise(REXML::Writer::Error) { writer.finish }
    end

    def test_short_write_breaks_writer
      sink = ShortWriteSink.new
      writer = REXML::Writer.new(sink)
      writer.start_element("root")
      assert_raise(REXML::Writer::Error) { writer.text("content") }
      assert(writer.broken?)
      assert_raise(REXML::Writer::Error) { writer.text("more") }
      assert_raise(REXML::Writer::Error) { writer.end_element }
      assert_raise(REXML::Writer::Error) { writer.finish }
      assert(!sink.closed?)
    end

    def test_io_exception_breaks_writer
      sink = FailingSink.new
      writer = REXML::Writer.new(sink)
      writer.start_element("root")
      assert_raise(IOError) { writer.text("content") }
      assert(writer.broken?)
      assert_raise(REXML::Writer::Error) { writer.end_element }
      assert(!sink.closed?)
    end

    def test_finish_does_not_close_io
      io = StringIO.new
      writer = REXML::Writer.new(io)
      writer.start_element("root")
      writer.end_element
      writer.finish
      assert(!io.closed?)
    end

    def test_streams_large_document_in_small_chunks
      sink = ChunkedSink.new
      writer = REXML::Writer.new(sink)
      writer.start_element("root")
      500.times do |index|
        writer.start_element("item")
        writer.attribute("id", index.to_s)
        writer.text("value #{index}")
        writer.end_element
      end
      writer.end_element
      writer.finish
      assert_operator(sink.content.bytesize, :>, 10_000)
      assert_operator(sink.max_chunk_size, :<, 200)
      document = REXML::Document.new(sink.content)
      assert_equal(500, document.root.elements.size)
    end

    def test_semantic_equivalence_with_dom_output
      xml = write_document do |writer|
        writer.comment("top")
        writer.start_element("{http://example.com/root}root")
        writer.attribute("id", "r1")
        writer.attribute("{http://example.com/attr}data", "a & b < c \"q\"")
        writer.start_element("{http://example.com/root}child")
        writer.text("text & <more>")
        writer.cdata("raw <data> & stuff")
        writer.end_element
        writer.start_element("{http://example.com/root}empty")
        writer.end_element
        writer.end_element
        writer.finish
      end

      document = REXML::Document.new
      document.add(REXML::Comment.new("top"))
      root = document.add_element("root", {"xmlns" => "http://example.com/root"})
      root.add_attribute("id", "r1")
      root.add_namespace("ex", "http://example.com/attr")
      root.add_attribute("ex:data", "a & b < c \"q\"")
      child = root.add_element("child")
      child.add_text("text & <more>")
      child.add(REXML::CData.new("raw <data> & stuff"))
      root.add_element("empty")
      dom_io = StringIO.new
      document.write(dom_io)

      from_writer = REXML::Document.new(xml)
      from_dom = REXML::Document.new(dom_io.string)
      assert_equal(canonical_document(from_dom), canonical_document(from_writer))
    end
  end
end
