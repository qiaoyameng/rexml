# frozen_string_literal: false

require "digest"
require_relative "../helper"

module REXMLTests
  class CanonicalFormatterTest < Test::Unit::TestCase
    def canonicalize(xml, mode: :canonical_1_1, with_comments: false,
                     inclusive_namespaces: nil, node: nil)
      document = REXML::Document.new(xml)
      formatter =
        if mode == :exclusive_1_0
          REXML::Formatters::ExclusiveXMLCanonicalization1_0
            .new(with_comments, inclusive_namespaces)
        else
          REXML::Formatters::CanonicalXML1_1.new(with_comments)
        end
      target = node ? REXML::XPath.first(document, node) : document
      output = +""
      formatter.write(target, output)
      output
    end

    class DocumentTest < self
      def test_basic_order_entities_empty_elements_and_utf8
        xml =
          '<?xml version="1.0"?>' \
          '<root b="2" a="&quot;&apos;&lt;&amp;>" z="&#13;&#9;">' \
          "<!-- ignored -->" \
          "<empty></empty>" \
          "<cdata><![CDATA[< & >]]></cdata>" \
          "<?pi data?>" \
          "<e>\u4E2D\u6587</e>" \
          "</root>"

        expected =
          "<root a=\"&quot;'&lt;&amp;>\" b=\"2\" z=\"&#xD;&#x9;\">" \
          "<empty></empty>" \
          "<cdata>&lt; &amp; &gt;</cdata>" \
          "<?pi data?>" \
          "<e>\u4E2D\u6587</e>" \
          "</root>"

        assert_equal(expected, canonicalize(xml))
        assert_equal(Encoding::UTF_8, canonicalize(xml).encoding)
      end

      def test_non_utf8_input_is_serialized_as_utf8
        xml =
          '<?xml version="1.0" encoding="ISO-8859-1"?><root>café</root>'
            .dup.force_encoding(Encoding::ISO_8859_1)

        output = canonicalize(xml)

        assert_equal(Encoding::UTF_8, output.encoding)
        assert_equal("<root>caf\u00E9</root>", output)
      end

      def test_with_comments
        xml = "<root><!-- keep --><?pi x?><child/></root>"

        assert_equal(
          "<root><!-- keep --><?pi x?><child></child></root>",
          canonicalize(xml, with_comments: true)
        )
      end

      def test_processing_instruction_data_is_preserved
        xml = "<root><?pi hello   world ?><child/></root>"

        assert_equal(
          "<root><?pi hello   world ?><child></child></root>",
          canonicalize(xml)
        )
      end

      def test_comments_and_processing_instructions_outside_root
        xml = "<?before value?><!-- c --><root/><?after?>"

        assert_equal(
          "<?before value?><!-- c --><root></root><?after?>",
          canonicalize(xml, with_comments: true)
        )
        assert_equal("<?before value?><root></root><?after?>", canonicalize(xml))
      end

      def test_w3c_canonical_xml_1_1_example
        xml = <<~XML
          <?xml version="1.0"?>
          <?xml-stylesheet href="doc.xsl" type="text/xsl"?>
          <doc>Hello, world!<!-- Comment 1 --></doc>
          <?pi-without-data?>
          <!-- Comment 2 -->
        XML

        expected =
          "<?xml-stylesheet href=\"doc.xsl\" type=\"text/xsl\"?>" \
          "<doc>Hello, world!</doc>" \
          "<?pi-without-data?>"

        assert_equal(expected, canonicalize(xml))
        assert_equal("0afacf716e9c36b6ae96f351ff53ac7498df13f2",
                     Digest::SHA1.hexdigest(canonicalize(xml)))
      end

      def test_namespace_and_attribute_order
        xml =
          "<r xmlns:a='http://a.example/' xmlns:b='http://b.example/' " \
          "b:x='2' a:x='1' c='3'/>"

        expected =
          "<r xmlns:a=\"http://a.example/\" xmlns:b=\"http://b.example/\" " \
          "c=\"3\" a:x=\"1\" b:x=\"2\"></r>"

        assert_equal(expected, canonicalize(xml))
        assert_equal(
          expected,
          canonicalize(xml, mode: :exclusive_1_0)
        )
      end

      def test_original_dom_is_not_modified
        xml = "<root xmlns='http://example/' b='2' a='1'><child/></root>"
        document = REXML::Document.new(xml)
        canonicalize(xml)

        assert_equal(%w[xmlns b a], document.root.attributes.keys)
        assert_equal("http://example/", document.root.namespaces["xmlns"])
      end
    end

    class ExclusiveTest < self
      def test_ancestor_namespaces_are_not_inherited
        assert_equal(
          "<n1:elem xmlns:n1=\"http://example/a\"></n1:elem>",
          canonicalize("<n0:root xmlns:n0='urn:0' xmlns:n1='http://example/a'>" \
                       "<n1:elem/></n0:root>",
                       mode: :exclusive_1_0, node: "//n1:elem")
        )
      end

      def test_inclusive_prefix_list
        xml =
          "<n0:purchaseOrders xmlns:n0='http://purchaseorders.example.org'>" \
          "<n0:item n1:price='5' xmlns:n1='http://prices.example.org'/>" \
          "</n0:purchaseOrders>"

        item = canonicalize(
          xml,
          mode: :exclusive_1_0,
          inclusive_namespaces: ["n1"],
          node: "//n0:item"
        )
        assert_equal(
          "<n0:item xmlns:n0=\"http://purchaseorders.example.org\" " \
          "xmlns:n1=\"http://prices.example.org\" n1:price=\"5\"></n0:item>",
          item
        )
      end

      def test_default_namespace_is_rendered_when_first_used
        xml =
          "<p:root xmlns:p='http://p.example/' xmlns='http://d.example/'>" \
          "<p:parent><child/></p:parent></p:root>"

        assert_equal(
          "<p:root xmlns:p=\"http://p.example/\">" \
          "<p:parent><child xmlns=\"http://d.example/\"></child>" \
          "</p:parent></p:root>",
          canonicalize(xml, mode: :exclusive_1_0)
        )
      end

      def test_unused_namespace_is_omitted_unless_inclusive
        xml = "<root xmlns:used='http://used/' xmlns:unused='http://unused/'>" \
              "<used:item/></root>"

        assert_equal(
          "<root><used:item xmlns:used=\"http://used/\"></used:item></root>",
          canonicalize(xml, mode: :exclusive_1_0)
        )
        assert_equal(
          "<root xmlns:unused=\"http://unused/\" " \
          "xmlns:used=\"http://used/\"><used:item></used:item></root>",
          canonicalize(xml)
        )
      end
    end

    class SubtreeTest < self
      def test_ancestor_default_namespace_is_undeclared
        xml =
          "<root xmlns='http://example/default'>" \
          "<foo xmlns=''><bar/></foo>" \
          "</root>"

        assert_equal(
          "<foo xmlns=\"\"><bar></bar></foo>",
          canonicalize(xml, node: "//foo")
        )
        assert_equal("<foo xmlns=\"\"><bar></bar></foo>",
                     canonicalize(xml, mode: :exclusive_1_0, node: "//foo"))
      end

      def test_ancestor_prefixed_namespace_is_rendered_at_subtree_root
        xml =
          "<root xmlns:p='http://example/p'>" \
          "<p:child><p:grandchild/></p:child></root>"

        expected =
          "<p:child xmlns:p=\"http://example/p\">" \
          "<p:grandchild></p:grandchild></p:child>"

        assert_equal(expected, canonicalize(xml, node: "//p:child"))
        assert_equal(expected,
                     canonicalize(xml, mode: :exclusive_1_0, node: "//p:child"))
      end

      def test_canonical_1_1_inherits_xml_lang
        xml = "<root xml:lang='en'><child><grandchild/></child></root>"

        assert_equal(
          "<child xml:lang=\"en\"><grandchild></grandchild></child>",
          canonicalize(xml, node: "//child")
        )
      end

      def test_canonical_1_1_overrides_inherited_xml_lang
        xml = "<root xml:lang='en'><child xml:lang='fr'/></root>"

        assert_equal(
          "<child xml:lang=\"fr\"></child>",
          canonicalize(xml, node: "//child")
        )
      end

      def test_canonical_1_1_ignores_empty_inherited_xml_lang
        xml = "<root xml:lang='en'><middle xml:lang=''><child/></middle></root>"

        assert_equal("<child></child>", canonicalize(xml, node: "//child"))
      end

      def test_canonical_1_1_inherits_xml_base
        xml =
          "<root xml:base='http://example.org/'>" \
          "<child xml:base='subtree/'><grandchild/></child></root>"

        assert_equal(
          "<child xml:base=\"http://example.org/subtree/\">" \
          "<grandchild></grandchild></child>",
          canonicalize(xml, node: "//child")
        )
      end

      def test_exclusive_does_not_inherit_xml_lang_or_base
        xml =
          "<root xml:lang='en' xml:base='http://example.org/'>" \
          "<child/></root>"

        assert_equal(
          "<child></child>",
          canonicalize(xml, mode: :exclusive_1_0, node: "//child")
        )
      end

      def test_original_attributes_are_not_modified_for_inherited_xml_base
        xml =
          "<root xml:base='http://example.org/'>" \
          "<child xml:base='subtree/'/></root>"
        document = REXML::Document.new(xml)
        child = REXML::XPath.first(document, "//child")
        canonicalize(xml, node: "//child")

        assert_equal("subtree/", child.attributes["xml:base"])
      end

      def test_external_entity_is_not_fetched
        xml =
          "<!DOCTYPE root [" \
          "<!ENTITY ext SYSTEM 'file:///nonexistent/canonical-entity'>]>" \
          "<root>&ext;</root>"

        assert_equal("<root>&amp;ext;</root>", canonicalize(xml))
      end

      def test_carriage_return_in_text
        document = REXML::Document.new("<root>a&#xD;b</root>")
        output = +""
        REXML::Formatters::CanonicalXML1_1.new.write(document, output)

        assert_equal("<root>a&#xD;b</root>", output)
      end
    end
  end
end
