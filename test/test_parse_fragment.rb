# frozen_string_literal: false

require "test/unit"

require "rexml/document"

module REXMLTests
  class TestParseFragment < Test::Unit::TestCase
    private

    def parse_fragment( source, context )
      REXML.parse_fragment(source, context: context)
    end

    public

    # Several sibling nodes are returned as independent nodes.
    def test_multiple_siblings
      context = REXML::Document.new("<r/>").root
      nodes = parse_fragment(
        "<a/>text<!--comment--><?pi target?><![CDATA[cdata]]><b/>",
        context)
      assert_equal([
                     REXML::Element,
                     REXML::Text,
                     REXML::Comment,
                     REXML::Instruction,
                     REXML::CData,
                     REXML::Element,
                   ],
                   nodes.map(&:class))
      assert_equal(["a", "b"], nodes.values_at(0, 5).map(&:name))
      assert(nodes.none? { |node| node.parent })
    end

    def test_whitespace_only_fragment
      context = REXML::Document.new("<r/>").root
      nodes = parse_fragment("  \n\t ", context)
      assert_equal([REXML::Text], nodes.map(&:class))
      assert_equal("  \n\t ", nodes.first.value)
    end

    def test_empty_fragment
      context = REXML::Document.new("<r/>").root
      assert_equal([], parse_fragment("", context))
    end

    def test_text_before_and_after_elements
      context = REXML::Document.new("<r/>").root
      nodes = parse_fragment("before<a/>middle<b/>after", context)
      assert_equal(["before", "a", "middle", "b", "after"],
                   nodes.map { |node| node.is_a?(REXML::Element) ? node.name : node.value })
    end

    def test_inherits_default_namespace
      context = REXML::Document.new('<root xmlns="urn:default"/>').root
      nodes = parse_fragment("<a><b/></a>", context)
      nodes.each { |node| context.add(node) }
      assert_equal("urn:default", context.elements["a"].namespace)
      assert_equal("urn:default", context.elements["a/b"].namespace)
    end

    def test_inherits_prefixed_namespaces
      document = REXML::Document.new('<root xmlns:p="urn:p"/>')
      nodes = parse_fragment('<p:a p:b="1"/>', document.root)
      nodes.each { |node| document.root.add(node) }
      element = document.root.elements["p:a"]
      assert_equal("urn:p", element.namespace)
      assert_equal("urn:p", element.attribute("p:b").namespace)
    end

    def test_default_namespace_undeclaration_is_scoped
      document = REXML::Document.new('<root xmlns="urn:default"><inner/></root>')
      context = document.root.elements["inner"]
      nodes = parse_fragment('<a xmlns=""><b/></a><c/>', context)
      nodes.each { |node| context.add(node) }
      assert_equal("", context.elements["a"].namespace)
      assert_equal("", context.elements["a/b"].namespace)
      assert_equal("urn:default", context.elements["c"].namespace)
    end

    def test_prefix_rebinding_is_scoped
      document = REXML::Document.new('<root xmlns:p="urn:outer"/>')
      nodes = parse_fragment(
        '<p:a xmlns:p="urn:inner"><p:b/></p:a><p:c/>',
        document.root)
      nodes.each { |node| document.root.add(node) }
      assert_equal("urn:inner", document.root.elements["p:a"].namespace)
      assert_equal("urn:inner", document.root.elements["p:a/p:b"].namespace)
      assert_equal("urn:outer", document.root.elements["p:c"].namespace)
    end

    def test_unbound_element_prefix_is_rejected
      context = REXML::Document.new('<root xmlns:p="urn:p"/>').root
      assert_raise(REXML::UndefinedNamespaceException) do
        parse_fragment("<u:a/>", context)
      end
    end

    def test_unbound_attribute_prefix_is_rejected
      context = REXML::Document.new('<root xmlns:p="urn:p"/>').root
      assert_raise(REXML::UndefinedNamespaceException) do
        parse_fragment('<a u:b="1"/>', context)
      end
    end

    def test_prefix_leaving_scope_is_rejected
      context = REXML::Document.new('<root xmlns:p="urn:p"/>').root
      assert_raise(REXML::UndefinedNamespaceException) do
        parse_fragment('<a xmlns:u="urn:u"><u:b/></a><u:c/>', context)
      end
    end

    def test_end_tag_closing_context_element_is_rejected
      context = REXML::Document.new("<root/>").root
      assert_raise(REXML::ParseException) do
        parse_fragment("</root>", context)
      end
      assert_raise(REXML::ParseException) do
        parse_fragment("<a/></root>", context)
      end
    end

    def test_mismatched_end_tag_is_rejected
      context = REXML::Document.new("<root/>").root
      assert_raise(REXML::ParseException) do
        parse_fragment("<a></b>", context)
      end
    end

    def test_unclosed_element_is_rejected
      context = REXML::Document.new("<root/>").root
      assert_raise(REXML::ParseException) do
        parse_fragment("<a><b/></a><c>", context)
      end
    end

    def test_xml_declaration_is_rejected
      context = REXML::Document.new("<root/>").root
      assert_raise(REXML::ParseException) do
        parse_fragment('<?xml version="1.0"?><a/>', context)
      end
    end

    def test_doctype_is_rejected
      context = REXML::Document.new("<root/>").root
      assert_raise(REXML::ParseException) do
        parse_fragment("<!DOCTYPE root><a/>", context)
      end
    end

    def test_context_is_not_modified
      document = REXML::Document.new('<root xmlns:p="urn:p"/>')
      context = document.root
      before = context.to_s
      parse_fragment('<p:a xmlns:q="urn:q"><q:b/></p:a>text<!--c-->', context)
      assert_equal(before, context.to_s)
      assert_equal([], context.children.to_a)
    end

    def test_error_position_is_relative_to_fragment
      context = REXML::Document.new("<root/>").root
      error = assert_raise(REXML::ParseException) do
        parse_fragment("<a><b><c></b></a>", context)
      end
      assert_equal(13, error.position)
    end

    def test_accepts_io_source
      require "stringio"
      context = REXML::Document.new("<root/>").root
      nodes = parse_fragment(StringIO.new("<a/>text"), context)
      assert_equal([REXML::Element, REXML::Text], nodes.map(&:class))
    end

    def test_requires_element_context
      assert_raise(ArgumentError) do
        REXML.parse_fragment("<a/>", context: Object.new)
      end
    end

    def test_document_parse_still_requires_single_root
      assert_raise(REXML::ParseException) do
        REXML::Document.new("<a/><b/>")
      end
      assert_raise(REXML::ParseException) do
        REXML::Document.new("text<a/>")
      end
    end

    def test_document_class_method
      document = REXML::Document.new('<root xmlns:p="urn:p"/>')
      nodes = REXML::Document.parse_fragment("<p:a/>", context: document.root)
      assert_equal(["p:a"], nodes.map(&:expanded_name))
    end
  end
end
