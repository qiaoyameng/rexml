# frozen_string_literal: true

module REXMLTests
  class PrettyPreserveContentFormatterTest < Test::Unit::TestCase
    def format(node, indentation = 2)
      formatter = REXML::Formatters::Pretty.new(indentation)
      formatter.preserve_content = true
      output = +""
      formatter.write(node, output)
      output
    end

    def format_string(xml, indentation = 2)
      format(REXML::Document.new(xml), indentation)
    end

    def legacy_format(node, indentation = 2)
      formatter = REXML::Formatters::Pretty.new(indentation)
      output = +""
      formatter.write(node, output)
      output
    end

    class DefaultOffTest < self
      def test_disabled_by_default
        formatter = REXML::Formatters::Pretty.new
        assert_equal(false, formatter.preserve_content)
      end

      def test_legacy_output_is_unchanged_for_mixed_content
        document = REXML::Document.new("<p>Hello <b>bold</b> world</p>")
        expected = <<~EXPECTED.chomp
          <p>
            Hello 
            <b>
              bold
            </b>
             world
          </p>
        EXPECTED
        assert_equal(expected, legacy_format(document))
      end
    end

    class MixedContentTest < self
      def test_text_element_text_stays_on_one_line
        xml = "<root><p>Hello <b>bold</b> world</p></root>"
        expected = <<~EXPECTED.chomp
          <root>
            <p>Hello <b>bold</b> world</p>
          </root>
        EXPECTED
        assert_equal(expected, format_string(xml))
      end

      def test_internal_whitespace_is_not_collapsed
        xml = "<p>a  <b>x\ty</b>  b</p>"
        assert_equal(xml, format_string(xml))
      end

      def test_nested_inline_elements_keep_their_sequence
        xml = "<p>before <b>b<i>bi</i>tail</b> after</p>"
        assert_equal(xml, format_string(xml))
      end

      def test_reparse_preserves_text_and_element_interleaving
        xml = "<root><p>Hello <b>bold</b> middle <i>italic</i> end</p></root>"
        formatted = format_string(xml)
        reparsed = REXML::Document.new(formatted)

        sequence = tokens(reparsed.root.elements["p"])
        assert_equal(
          [[:text, "Hello "],
           [:element, "b"],
           [:text, " middle "],
           [:element, "i"],
           [:text, " end"]],
          sequence
        )
      end

      def test_reparse_preserves_text_contents
        xml = "<root><p>Hello <b>bold</b> world</p></root>"
        paragraph = REXML::Document.new(format_string(xml)).root.elements["p"]
        text_values = paragraph.children.filter_map do |child|
          child.value if child.is_a?(REXML::Text) && !child.is_a?(REXML::CData)
        end
        assert_equal(["Hello ", " world"], text_values)
        assert_equal("bold", paragraph.elements["b"].text)
      end

      def test_element_only_content_is_still_indented
        xml = "<root><a><b/><c><d>x</d></c></a></root>"
        expected = <<~EXPECTED.chomp
          <root>
            <a>
              <b/>
              <c>
                <d>x</d>
              </c>
            </a>
          </root>
        EXPECTED
        assert_equal(expected, format_string(xml))
      end

      def test_indentation_only_whitespace_between_elements_is_dropped
        xml = "<a>\n  <b/>\n  <c/>\n</a>"
        expected = "<a>\n  <b/>\n  <c/>\n</a>"
        assert_equal(expected, format_string(xml))
      end

      def test_trailing_text_is_detected
        xml = "<root><a><b/></a>tail</root>"
        assert_equal(xml, format_string(xml))
      end

      def test_leading_text_is_detected
        xml = "<root>head<a><b/></a></root>"
        assert_equal(xml, format_string(xml))
      end

      def test_comment_between_text_segments_keeps_content_verbatim
        xml = "<p>head<!-- note -->tail</p>"
        assert_equal(xml, format_string(xml))
      end

      def test_processing_instruction_between_text_segments_is_verbatim
        xml = "<p>head<?pi data?>tail</p>"
        assert_equal(xml, format_string(xml))
      end

      def test_comments_between_elements_stay_block_formatted
        xml = "<a><b/><!-- note --><c/></a>"
        expected = <<~EXPECTED.chomp
          <a>
            <b/>
            <!-- note -->
            <c/>
          </a>
        EXPECTED
        assert_equal(expected, format_string(xml))
      end

      private

      def tokens(element)
        element.children.filter_map do |child|
          case child
          when REXML::Element
            [:element, child.expanded_name]
          when REXML::Text
            [:text, child.value]
          end
        end
      end
    end

    class CDataTest < self
      def test_cdata_marks_content_as_mixed
        xml = "<root><a><![CDATA[  hi  ]]><b/></a></root>"
        expected = <<~EXPECTED.chomp
          <root>
            <a><![CDATA[  hi  ]]><b/></a>
          </root>
        EXPECTED
        assert_equal(expected, format_string(xml))
      end

      def test_whitespace_only_cdata_between_elements_is_preserved
        xml = "<a><b/><![CDATA[  ]]><c/></a>"
        assert_equal(xml, format_string(xml))
      end
    end

    class EntityWhitespaceTest < self
      def test_hex_character_reference_whitespace_is_preserved
        xml = "<p><b>x</b>&#x20;<i>y</i></p>"
        assert_equal(xml, format_string(xml))
      end

      def test_decimal_character_reference_whitespace_is_preserved
        xml = "<p><b>x</b>&#32;<i>y</i></p>"
        assert_equal(xml, format_string(xml))
      end

      def test_general_entity_whitespace_is_preserved
        xml = <<~XML.chomp
          <!DOCTYPE root [<!ENTITY sp "  ">]>
          <root><p><b>x</b>&sp;<i>y</i></p></root>
        XML
        formatted = format_string(xml)
        reparsed = REXML::Document.new(formatted)
        paragraph = reparsed.root.elements["p"]
        text_values = paragraph.children.filter_map do |child|
          child.value if child.is_a?(REXML::Text) && !child.is_a?(REXML::CData)
        end
        assert_equal(["  "], text_values)
        assert_equal(%w[b i],
                     paragraph.children.select { |c| c.is_a?(REXML::Element) }
                              .map(&:expanded_name))
      end
    end

    class XmlSpaceTest < self
      def test_preserve_attribute_forbids_inserting_whitespace
        xml = %q{<a xml:space="preserve">  <b>x   y</b>  </a>}
        assert_equal(xml.sub('xml:space="preserve"', "xml:space='preserve'"),
                     format_string(xml))
      end

      def test_preserve_is_inherited_from_ancestor
        xml = %q{<a xml:space="preserve"><b><c>  x  </c></b></a>}
        assert_equal(xml.sub('xml:space="preserve"', "xml:space='preserve'"),
                     format_string(xml))
      end

      def test_default_inside_mixed_preserved_content_stays_verbatim
        # Significant text surrounds the inner "default" element, so nothing
        # in this subtree may be moved onto a line of its own.
        xml = %q{<a xml:space="preserve">pre<c xml:space="default"><d>  <e/>  </d></c>post</a>}
        expected = %q{<a xml:space='preserve'>pre<c xml:space='default'><d>  <e/>  </d></c>post</a>}
        formatted = format_string(xml)
        assert_equal(expected, formatted)
        reparsed = REXML::Document.new(formatted)
        assert_equal(["pre", "post"],
                     reparsed.root.children.grep(REXML::Text).map(&:value))
      end

      def test_default_restores_block_layout_without_adjacent_text
        xml = %q{<a xml:space="preserve"><b>keep  me</b><c xml:space="default"><d>  <e/>  </d></c></a>}
        formatted = format_string(xml)
        assert_include(formatted, "<b>keep  me</b>")
        assert_include(formatted,
                       "<c xml:space='default'>\n    <d>\n      <e/>\n    </d>\n  </c>")
        assert_equal(formatted, format_string(formatted))
      end

      def test_inner_default_is_not_inherited_as_preserve
        xml = %q{<a xml:space="preserve"><b xml:space="default">  <c/>  </b></a>}
        expected = <<~EXPECTED.chomp
          <a xml:space='preserve'>
            <b xml:space='default'>
              <c/>
            </b>
          </a>
        EXPECTED
        assert_equal(expected, format_string(xml))
      end

      def test_deep_preserve_default_preserve_switches
        xml = %q{<r xml:space="preserve"><a>  <b xml:space="default"><c>  <d xml:space="preserve">  x  </d>  </c></b>  </a></r>}
        once = format_string(xml)
        twice = format_string(once)
        assert_equal(once, twice)
        assert_include(once, "<d xml:space='preserve'>  x  </d>")
      end

      def test_invalid_value_raises_argument_error
        error = assert_raise(ArgumentError) do
          format_string(%q{<a xml:space="on"><b/></a>})
        end
        assert_include(error.message, "xml:space")
      end

      def test_invalid_value_on_empty_element_raises
        assert_raise(ArgumentError) do
          format_string(%q{<a xml:space="bad"/>})
        end
      end

      def test_invalid_value_inheriting_preserve_still_raises
        assert_raise(ArgumentError) do
          format_string(%q{<a xml:space="preserve"><b xml:space="no"/></a>})
        end
      end
    end

    class IdempotenceTest < self
      def test_mixed_content_is_idempotent
        assert_steady_state("<root><p>Hello <b>bold</b> world</p></root>")
      end

      def test_xml_space_switches_are_idempotent
        xml = %q{<r><a xml:space="preserve">  <b>x   y</b>  <c xml:space="default"><d>  <e/>  </d></c></a></r>}
        assert_steady_state(xml)
      end

      def test_entity_whitespace_is_idempotent
        assert_steady_state("<p><b>x</b>&#x20;<i>y</i></p>")
      end

      def test_cdata_is_idempotent
        assert_steady_state("<a>x<![CDATA[  ]]><b/></a>")
      end

      def test_comment_pi_interleaving_is_idempotent
        assert_steady_state("<r>head<!-- c --><b/>mid<?pi x?>tail</r>")
      end

      private

      def assert_steady_state(xml)
        first = format_string(xml)
        second = format_string(first)
        third = format_string(second)
        assert_equal(first, second)
        assert_equal(second, third)
      end
    end

    class CombinedDocumentTest < self
      def test_text_bold_text_with_space_layers_round_trips
        xml = <<~XML.chomp
          <doc>
            <section>
              <title>Title</title>
              <para>Some <strong>bold</strong> text with <em>emphasis</em>.</para>
              <preserved xml:space="preserve"> keep <b>  this  </b> as is </preserved>
            </section>
          </doc>
        XML
        formatted = format_string(xml)

        reparsed = REXML::Document.new(formatted)
        paragraph = reparsed.root.elements["section/para"]
        assert_equal(
          [[:text, "Some "], [:element, "strong"],
           [:text, " text with "], [:element, "em"], [:text, "."]],
          paragraph.children.filter_map do |child|
            case child
            when REXML::Element then [:element, child.expanded_name]
            when REXML::Text then [:text, child.value]
            end
          end
        )

        preserved = reparsed.root.elements["section/preserved"]
        assert_equal(" keep <b>  this  </b> as is ", preserved.children.map { |c|
          c.is_a?(REXML::Element) ? "<b>#{c.text}</b>" : c.value
        }.join)

        assert_equal(formatted, format_string(formatted))
      end
    end
  end
end
