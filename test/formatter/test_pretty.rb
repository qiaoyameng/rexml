module REXMLTests
  class PrettyFormatterTest < Test::Unit::TestCase
    def format(node, indentation=2)
      formatter = REXML::Formatters::Pretty.new(indentation)
      output = +""
      formatter.write(node, output)
      output
    end

    class TextTest < self
      def test_source_document_is_not_modified
        document = REXML::Document.new("<a><b>hello   world</b></a>")
        format(document)
        assert_equal("<a><b>hello   world</b></a>", document.to_s)
      end

      def test_raw_text_value_is_not_modified
        text = REXML::Text.new("hello   world", true, nil, true)
        format(text)
        assert_equal("hello   world", text.value)
      end

      def test_whitespace_is_replaced_with_space
        document = REXML::Document.new("<a><b>x\ty</b></a>")
        assert_equal("<a>\n  <b>\n    x y\n  </b>\n</a>", format(document))
      end

      def test_consecutive_spaces_are_squeezed
        document = REXML::Document.new("<a><b>x   y</b></a>")
        assert_equal("<a>\n  <b>\n    x y\n  </b>\n</a>", format(document))
      end
    end

    class PreserveContentTest < self
      def format_preserve(node, indentation=2)
        formatter = REXML::Formatters::Pretty.new(indentation)
        formatter.preserve_content = true
        output = +""
        formatter.write(node, output)
        output
      end

      def format_preserve_source(source)
        format_preserve(REXML::Document.new(source))
      end

      def content_segments(element)
        element.children.map do |child|
          case child
          when REXML::CData
            [:cdata, child.to_s]
          when REXML::Text
            [:text, child.to_s]
          when REXML::Element
            [:element, child.expanded_name]
          when REXML::Comment
            [:comment, child.to_s]
          when REXML::Instruction
            [:instruction, child.target, child.content]
          end
        end
      end

      def assert_segments_preserved(source, xpath="/root")
        original = REXML::Document.new(source)
        formatted = REXML::Document.new(format_preserve_source(source))
        assert_equal(content_segments(REXML::XPath.first(original, xpath)),
                     content_segments(REXML::XPath.first(formatted, xpath)))
      end

      def test_mixed_content_is_kept_verbatim
        assert_equal("<p>Hello <b>bold</b> world</p>",
                     format_preserve_source("<p>Hello <b>bold</b> world</p>"))
      end

      def test_mixed_content_segments_survive_reparse
        assert_segments_preserved("<root>text <b>bold</b> more <i>x</i> end</root>")
      end

      def test_element_only_content_is_indented
        assert_equal("<a>\n  <b>\n    <c>x</c>\n  </b>\n  <d/>\n</a>",
                     format_preserve_source("<a><b><c>x</c></b><d/></a>"))
      end

      def test_whitespace_only_text_between_elements_is_reindented
        assert_equal("<a>\n  <b/>\n  <c/>\n</a>",
                     format_preserve_source("<a> <b/>\n   <c/> </a>"))
      end

      def test_text_only_element_is_kept_verbatim
        assert_equal("<a>\n  <b>x   y\n z</b>\n</a>",
                     format_preserve_source("<a><b>x   y\n z</b></a>"))
      end

      def test_cdata_makes_content_mixed
        assert_equal("<a><b/><![CDATA[ ]]><c/></a>",
                     format_preserve_source("<a><b/><![CDATA[ ]]><c/></a>"))
        assert_equal("<a><b/><![CDATA[x < y]]><c/></a>",
                     format_preserve_source("<a><b/><![CDATA[x < y]]><c/></a>"))
      end

      def test_entity_expanded_whitespace_is_character_data
        assert_equal("<a><b/>&#32;<c/></a>",
                     format_preserve_source("<a><b/>&#32;<c/></a>"))
      end

      def test_text_around_comment_is_mixed
        assert_equal("<p>t1<!-- c -->t2</p>",
                     format_preserve_source("<p>t1<!-- c -->t2</p>"))
      end

      def test_text_around_instruction_is_mixed
        assert_equal("<p>t1<?pi data?>t2</p>",
                     format_preserve_source("<p>t1<?pi data?>t2</p>"))
      end

      def test_first_child_does_not_decide
        assert_equal("<p><!-- c -->tail</p>",
                     format_preserve_source("<p><!-- c -->tail</p>"))
        assert_equal("<p><b/>tail</p>",
                     format_preserve_source("<p><b/>tail</p>"))
        assert_equal("<p>lead<b/></p>",
                     format_preserve_source("<p>lead<b/></p>"))
      end

      def test_comment_and_instruction_in_element_content_are_indented
        assert_equal("<a>\n  <b/>\n  <!-- c -->\n  <?pi data?>\n  <c/>\n</a>",
                     format_preserve_source("<a><b/><!-- c --><?pi data?><c/></a>"))
      end

      def test_xml_space_preserve_keeps_subtree_verbatim
        source = "<a xml:space=\"preserve\">  <b> x  y </b>\n  <c/>\n</a>"
        assert_equal(source.gsub(/\"/, "'"),
                     format_preserve_source(source))
      end

      def test_xml_space_is_inherited_from_ancestor
        source = "<a xml:space=\"preserve\"><b>  <c/>  </b></a>"
        assert_equal(source.gsub(/\"/, "'"),
                     format_preserve_source(source))
      end

      def test_xml_space_default_restores_normal_rules
        source = "<root><a xml:space=\"preserve\">  " \
                 "<b xml:space=\"default\"><c/><d/></b>  </a></root>"
        assert_equal("<root>\n" \
                     "  <a xml:space='preserve'>  <b xml:space='default'>\n" \
                     "    <c/>\n" \
                     "    <d/>\n" \
                     "  </b>  </a>\n" \
                     "</root>",
                     format_preserve_source(source))
      end

      def test_xml_space_nested_preserve_after_default
        source = "<root xml:space=\"preserve\">" \
                 "<a xml:space=\"default\"><b/><c xml:space=\"preserve\">  <d/>  </c></a>" \
                 "</root>"
        assert_equal("<root xml:space='preserve'>" \
                     "<a xml:space='default'>\n" \
                     "  <b/>\n" \
                     "  <c xml:space='preserve'>  <d/>  </c>\n" \
                     "</a>" \
                     "</root>",
                     format_preserve_source(source))
      end

      def test_xml_space_preserve_segments_survive_reparse
        assert_segments_preserved(
          "<root><a xml:space=\"preserve\">  <b xml:space=\"default\">" \
          "<c/><d/></b>  tail</a></root>",
          "/root/a")
      end

      def test_invalid_xml_space_value_raises
        error = assert_raise(ArgumentError) do
          format_preserve_source("<a xml:space=\"bogus\"><b/></a>")
        end
        assert_include(error.message, "bogus")
      end

      def test_invalid_xml_space_value_on_ancestor_raises
        assert_raise(ArgumentError) do
          format_preserve_source("<a xml:space=\"keep\"><b><c/></b></a>")
        end
      end

      def test_disabled_mode_keeps_old_output
        document = REXML::Document.new("<p>Hello <b>bold</b> world</p>")
        assert_equal("<p>\n  Hello \n  <b>\n    bold\n  </b>\n   world\n</p>",
                     format(document))
      end

      def test_repeated_formatting_does_not_add_whitespace
        [
          "<a><b><c>x</c></b><d/></a>",
          "<p>Hello <b>bold</b> world</p>",
          "<root><a xml:space=\"preserve\">  <b xml:space=\"default\">" \
            "<c/><d/></b>  </a><e><f/><g/></e></root>",
          "<a><b/><!-- c --><?pi data?><c/></a>",
          "<a><b/><![CDATA[ ]]><c/></a>",
        ].each do |source|
          once = format_preserve_source(source)
          twice = format_preserve_source(once)
          assert_equal(once, twice, "not idempotent for #{source.inspect}")
        end
      end
    end
  end
end
