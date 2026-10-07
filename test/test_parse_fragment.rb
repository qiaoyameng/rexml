# frozen_string_literal: false

require_relative "helper"

module REXMLTests
  class TestParseFragment < Test::Unit::TestCase
    def parse_fragment(source, context_source = nil)
      context_source ||= "<root xmlns='urn:default' xmlns:x='urn:x'/>"
      context = REXML::Document.new(context_source).root
      REXML::Document.parse_fragment(source, context: context)
    end

    def test_multiple_sibling_nodes
      fragment = parse_fragment("text<x:a/><x:b/>tail")
      assert_equal(4, fragment.children.size)
      assert_equal("text", fragment.children[0].value)
      assert_equal("x:a", fragment.children[1].expanded_name)
      assert_equal("x:b", fragment.children[2].expanded_name)
      assert_equal("tail", fragment.children[3].value)
    end

    def test_interleaved_node_types
      fragment = parse_fragment("text<a/><!--note--><?go instruction?><b/>")
      assert_equal(
        [REXML::Text, REXML::Element, REXML::Comment,
         REXML::Instruction, REXML::Element],
        fragment.children.map(&:class)
      )
      assert_equal("text<a/><!--note--><?go instruction?><b/>",
                   fragment.to_s)
    end

    def test_document_new_still_requires_complete_document
      assert_raise(REXML::ParseException) do
        REXML::Document.new("<a/><b/>")
      end
      assert_raise(REXML::ParseException) do
        REXML::Document.new("content at the start<a/>")
      end
    end

    def test_default_namespace_is_inherited
      fragment = parse_fragment("<child><grand/></child>")
      assert_equal("urn:default", fragment.children[0].namespace)
      assert_equal("urn:default",
                   fragment.children[0].elements[1].namespace)
    end

    def test_prefixed_name_uses_inherited_namespace
      fragment = parse_fragment("<x:a x:attr='1'/>")
      element = fragment.children[0]
      assert_equal("urn:x", element.namespace("x"))
      assert_equal("urn:x", element.attributes.get_attribute("x:attr").namespace)
    end

    def test_prefix_rebinding_is_scoped
      fragment = parse_fragment(
        "<x:a xmlns:x='urn:rebound'><x:b/></x:a><x:c/>"
      )
      rebound = fragment.children[0]
      assert_equal("urn:rebound", rebound.namespace("x"))
      assert_equal("urn:rebound", rebound.elements[1].namespace("x"))
      inherited = fragment.children[1]
      assert_equal("urn:x", inherited.namespace("x"))
    end

    def test_inner_declaration_does_not_leak
      assert_raise(REXML::UndefinedNamespaceException) do
        parse_fragment("<a xmlns:z='urn:z'><z:b/></a><z:c/>")
      end
    end

    def test_undefined_prefix_is_rejected
      assert_raise(REXML::UndefinedNamespaceException) do
        parse_fragment("<y:a/>")
      end
      assert_raise(REXML::UndefinedNamespaceException) do
        parse_fragment("<a y:attr='1'/>")
      end
    end

    def test_xml_declaration_is_rejected
      error = assert_raise(REXML::ParseException) do
        parse_fragment("<?xml version='1.0'?><a/>")
      end
      assert_match(/XML declaration/, error.message)
    end

    def test_doctype_is_rejected
      assert_raise(REXML::ParseException) do
        parse_fragment("<!DOCTYPE root><a/>")
      end
    end

    def test_end_tag_cannot_escape_fragment_boundary
      error = assert_raise(REXML::ParseException) do
        parse_fragment("</root>")
      end
      assert_match(/\AUnexpected top-level end tag \(got 'root'\)/,
                   error.message)
    end

    def test_end_tag_cannot_escape_after_siblings
      assert_raise(REXML::ParseException) do
        parse_fragment("<a/><b></b></root><c/>")
      end
    end

    def test_context_is_not_modified
      context = REXML::Document.new(
        "<root xmlns='urn:default' xmlns:x='urn:x'/>"
      ).root
      namespaces_before = context.namespaces
      serialization_before = context.document.to_s
      parse_fragment("<x:a xmlns:q='urn:q'><q:b/></x:a>")
      assert_equal(namespaces_before, context.namespaces)
      assert_equal(serialization_before, context.document.to_s)
    end

    def test_error_position_is_relative_to_fragment
      error = assert_raise(REXML::ParseException) do
        parse_fragment("ok\n<unclosed")
      end
      assert_equal(2, error.line)
    end

    def test_fragment_is_independent
      fragment = parse_fragment("<x:a/>")
      assert_nil(fragment.document)
      assert_nil(fragment.children[0].document)
      assert_equal(:document_fragment, fragment.node_type)
    end

    def test_moving_node_requires_explicit_namespace_fixup
      fragment = parse_fragment("<x:a/>")
      child = fragment.children[0]
      assert_equal("urn:x", child.namespace("x"))

      target = REXML::Document.new("<elsewhere/>").root
      target.add_element(child)
      # The expanded name is unchanged, but the binding does not
      # travel with the node...
      assert_equal("x:a", child.expanded_name)
      assert_nil(child.namespace("x"))

      # ...it must be restored explicitly at the new location.
      target.add_namespace("x", "urn:x")
      assert_equal("urn:x", child.namespace("x"))
    end

    def test_empty_fragment
      assert_equal([], parse_fragment("").children)
    end

    def test_text_only_fragment
      assert_equal("just text", parse_fragment("just text").to_s)
    end
  end
end
