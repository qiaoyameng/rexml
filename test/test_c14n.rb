# frozen_string_literal: false

require "digest"

module REXMLTests
  class C14NTest < Test::Unit::TestCase
    C14N11 = REXML::C14N::CANONICAL_XML_1_1
    EXC_C14N = REXML::C14N::EXCLUSIVE_XML_CANONICALIZATION_1_0

    def canonicalize(source, **options)
      REXML::Document.new(source).canonicalize(**options)
    end

    # The motivating use case: two documents that differ only in
    # attribute order, quote style, and empty-element spelling must
    # canonicalize to identical bytes.
    def test_equivalent_documents_produce_identical_bytes
      first = canonicalize(%q{<a z="1" y="2" x="3"><b></b><c/></a>})
      second = canonicalize(%q{<a x='3' y='2' z='1'><b/><c></c></a>})
      assert_equal(%q{<a x="3" y="2" z="1"><b></b><c></c></a>}, first)
      assert_equal(first, second)
      assert_equal(Digest::SHA256.digest(first), Digest::SHA256.digest(second))
    end

    def test_output_is_utf_8
      output = canonicalize("<doc>\u00a9\u00e9</doc>")
      assert_equal(Encoding::UTF_8, output.encoding)
      assert_equal("<doc>\u00a9\u00e9</doc>".b, output.b)
    end

    # W3C Canonical XML 1.0/1.1, Example 3.1: PIs, comments, and the
    # document type declaration outside the document element.
    # Note: REXML's parser strips leading/trailing whitespace of PI
    # content, so the expected bytes reflect the parsed DOM.
    EXAMPLE_3_1 = <<-XML
<?xml version="1.0"?>

<?xml-stylesheet   href="doc.xsl"
   type="text/xsl"   ?>

<!DOCTYPE doc SYSTEM "doc.dtd">

<doc>Hello, world!<!-- Comment 1 --></doc>

<?pi-without-data     ?>

<!-- Comment 2 -->

<!-- Comment 3 -->
    XML

    def test_w3c_example_3_1_without_comments
      expected = "<?xml-stylesheet href=\"doc.xsl\"\n" \
                 "   type=\"text/xsl\"?>" \
                 "<doc>Hello, world!</doc>" \
                 "<?pi-without-data?>"
      assert_equal(expected, canonicalize(EXAMPLE_3_1))
    end

    def test_w3c_example_3_1_with_comments
      expected = "<?xml-stylesheet href=\"doc.xsl\"\n" \
                 "   type=\"text/xsl\"?>" \
                 "<doc>Hello, world!<!-- Comment 1 --></doc>" \
                 "<?pi-without-data?>" \
                 "<!-- Comment 2 -->" \
                 "<!-- Comment 3 -->"
      assert_equal(expected, canonicalize(EXAMPLE_3_1, comments: true))
    end

    def test_comments_inside_elements
      source = "<doc><!-- c --><e/><!-- d --></doc>"
      assert_equal("<doc><e></e></doc>", canonicalize(source))
      assert_equal("<doc><!-- c --><e></e><!-- d --></doc>",
                   canonicalize(source, comments: true))
    end

    # W3C Canonical XML 1.0/1.1, Example 3.3: start/end tags, empty
    # elements, attribute and namespace declaration ordering, default
    # attribute values from the DTD, and default namespace
    # undeclarations.  (Namespace declarations precede the attributes
    # that use their prefixes, as required by REXML's parser.)
    EXAMPLE_3_3 = <<-XML
<!DOCTYPE doc [<!ATTLIST e9 attr CDATA "default">]>
<doc>
   <e1   />
   <e2   ></e2>
   <e3   name = "elem3"   id="elem3"   />
   <e4   name="elem4"   id="elem4"   ></e4>
   <e5 xmlns:b="http://www.ietf.org"
       xmlns:a="http://www.w3.org"
       xmlns="http://example.org"
       a:attr="out" b:attr="sorted" attr2="all" attr="I'm"/>
   <e6 xmlns="" xmlns:a="http://www.w3.org">
       <e7 xmlns="http://www.ietf.org">
           <e8 xmlns="" xmlns:a="http://www.w3.org">
               <e9 xmlns="" xmlns:a="http://www.ietf.org"/>
           </e8>
       </e7>
   </e6>
</doc>
    XML

    EXAMPLE_3_3_EXPECTED = <<-XML.chomp
<doc>
   <e1></e1>
   <e2></e2>
   <e3 id="elem3" name="elem3"></e3>
   <e4 id="elem4" name="elem4"></e4>
   <e5 xmlns="http://example.org" xmlns:a="http://www.w3.org" xmlns:b="http://www.ietf.org" attr="I'm" attr2="all" b:attr="sorted" a:attr="out"></e5>
   <e6 xmlns:a="http://www.w3.org">
       <e7 xmlns="http://www.ietf.org">
           <e8 xmlns="">
               <e9 xmlns:a="http://www.ietf.org" attr="default"></e9>
           </e8>
       </e7>
   </e6>
</doc>
    XML

    def test_w3c_example_3_3
      assert_equal(EXAMPLE_3_3_EXPECTED, canonicalize(EXAMPLE_3_3))
    end

    def test_w3c_example_3_3_digest
      assert_equal("35de49aa4bb3ea3aba49b4d87713195fe5529afc0ff367eaf70e47da39a962ca",
                   Digest::SHA256.hexdigest(canonicalize(EXAMPLE_3_3)))
    end

    # W3C Canonical XML 1.0/1.1, Example 3.4: character modifications
    # and character references.  (The parts of the example that require
    # DTD-driven non-CDATA attribute normalization are omitted; REXML
    # does not type attributes from ATTLIST declarations.)
    def test_w3c_example_3_4_escaping
      source = '<doc>' \
               '<text>First line&#x0d;&#10;Second line</text>' \
               '<value>&#x32;</value>' \
               '<compute><![CDATA[value>"0" && value<"10" ?"valid":"error"]]></compute>' \
               '<compute expr="value>&quot;0&quot; &amp;&amp; value&lt;&quot;10&quot;"/>' \
               '<norm attr=" &amp;   &#x20;&#13;&#xa;&#9;   "/>' \
               '</doc>'
      expected = '<doc>' \
                 "<text>First line&#xD;\nSecond line</text>" \
                 '<value>2</value>' \
                 '<compute>value&gt;"0" &amp;&amp; value&lt;"10" ?"valid":"error"</compute>' \
                 '<compute expr="value>&quot;0&quot; &amp;&amp; value&lt;&quot;10&quot;"></compute>' \
                 '<norm attr=" &amp;    &#xD;&#xA;&#x9;   "></norm>' \
                 '</doc>'
      assert_equal(expected, canonicalize(source))
    end

    def test_xml_declaration_and_doctype_are_excluded
      source = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" \
               "<!DOCTYPE doc [<!ENTITY e \"expanded\">]>\n" \
               "<doc>&e;</doc>"
      assert_equal("<doc>expanded</doc>", canonicalize(source))
    end

    # External entities must not be resolved (no network access); an
    # unresolved reference is canonicalized as its literal DOM text.
    def test_external_entity_is_not_expanded
      source = '<!DOCTYPE doc [<!ENTITY ext SYSTEM "http://example.invalid/x">]>' \
               '<doc>&ext;</doc>'
      assert_equal("<doc>&amp;ext;</doc>", canonicalize(source))
    end

    def test_dom_is_not_modified
      source = %q{<a z="1" y="2"><b/></a>}
      document = REXML::Document.new(source)
      serialized_before = document.to_s
      document.canonicalize
      document.root.canonicalize
      document.canonicalize(mode: EXC_C14N, comments: true)
      assert_equal(serialized_before, document.to_s)
    end

    def test_invalid_mode
      document = REXML::Document.new("<a/>")
      assert_raise(ArgumentError) do
        document.canonicalize(mode: :c14n10)
      end
    end

    def test_inclusive_prefixes_require_exclusive_mode
      document = REXML::Document.new("<a/>")
      assert_raise(ArgumentError) do
        document.canonicalize(inclusive_prefixes: ["n0"])
      end
    end

    def test_invalid_node
      assert_raise(REXML::C14N::Error) do
        REXML::C14N.canonicalize(REXML::Text.new("text"))
      end
    end

    module Subtree
      class InclusiveTest < Test::Unit::TestCase
        # Ancestor namespace declarations in scope at the subtree root
        # are copied to the apex element.
        def test_ancestor_namespaces_are_inherited
          document = REXML::Document.new(
            '<root xmlns:a="http://a" xmlns="http://d">' \
            '<child><a:grand/></child></root>'
          )
          assert_equal('<child xmlns="http://d" xmlns:a="http://a">' \
                       '<a:grand></a:grand></child>',
                       document.root.elements[1].canonicalize)
        end

        # Attributes in the xml namespace are inherited from ancestors;
        # the nearest ancestor wins and the apex element's own values
        # take precedence.
        def test_xml_attributes_are_inherited
          document = REXML::Document.new(
            '<root xml:lang="en" xml:base="http://example.com/base/">' \
            '<child><grand xml:lang="fr"/></child></root>'
          )
          assert_equal('<child xml:base="http://example.com/base/" xml:lang="en">' \
                       '<grand xml:lang="fr"></grand></child>',
                       document.root.elements[1].canonicalize)
          assert_equal('<grand xml:base="http://example.com/base/" xml:lang="fr">' \
                       '</grand>',
                       document.root.elements[1].elements[1].canonicalize)
        end

        # The ancestor default namespace is cancelled inside the
        # subtree: the undeclaration must be rendered when the
        # cancellation itself is part of the canonicalized subtree.
        def test_cancelled_ancestor_default_namespace
          document = REXML::Document.new(
            '<root xmlns="http://default">' \
            '<child xmlns=""><grand/></child></root>'
          )
          assert_equal('<root xmlns="http://default">' \
                       '<child xmlns=""><grand></grand></child></root>',
                       document.canonicalize)
          assert_equal('<child xmlns=""><grand></grand></child>',
                       document.root.elements[1].canonicalize)
          assert_equal('<grand></grand>',
                       document.root.elements[1].elements[1].canonicalize)
        end
      end

      class ExclusiveTest < Test::Unit::TestCase
        EXC = REXML::C14N::EXCLUSIVE_XML_CANONICALIZATION_1_0

        # W3C Exclusive XML Canonicalization 1.0, section 2.2 example:
        # ancestor declarations are not copied to the subtree root.
        EXAMPLE_SUBTREE = <<-XML
<n0:local xmlns:n0="foo:bar">
    <n1:elem2 xmlns:n1="http://example.net" xml:lang="en">
        <n3:stuff xmlns:n3="ftp://example.org"/>
    </n1:elem2>
</n0:local>
        XML

        def test_ancestor_namespaces_are_not_inherited
          document = REXML::Document.new(EXAMPLE_SUBTREE)
          elem2 = document.root.elements[1]
          expected = "<n1:elem2 xmlns:n1=\"http://example.net\" xml:lang=\"en\">\n" \
                     "        <n3:stuff xmlns:n3=\"ftp://example.org\"></n3:stuff>\n" \
                     "    </n1:elem2>"
          assert_equal(expected, elem2.canonicalize(mode: EXC))
        end

        def test_inclusive_mode_copies_ancestor_namespaces
          document = REXML::Document.new(EXAMPLE_SUBTREE)
          elem2 = document.root.elements[1]
          expected = "<n1:elem2 xmlns:n0=\"foo:bar\" xmlns:n1=\"http://example.net\" xml:lang=\"en\">\n" \
                     "        <n3:stuff xmlns:n3=\"ftp://example.org\"></n3:stuff>\n" \
                     "    </n1:elem2>"
          assert_equal(expected, elem2.canonicalize)
        end

        # The InclusiveNamespaces PrefixList forces prefixes to be
        # rendered inclusively at the subtree root.
        def test_inclusive_prefix_list
          document = REXML::Document.new(EXAMPLE_SUBTREE)
          elem2 = document.root.elements[1]
          expected = "<n1:elem2 xmlns:n0=\"foo:bar\" xmlns:n1=\"http://example.net\" xml:lang=\"en\">\n" \
                     "        <n3:stuff xmlns:n3=\"ftp://example.org\"></n3:stuff>\n" \
                     "    </n1:elem2>"
          assert_equal(expected,
                       elem2.canonicalize(mode: EXC, inclusive_prefixes: ["n0"]))
        end

        def test_unused_namespaces_are_dropped
          document = REXML::Document.new(
            '<root xmlns:unused="http://u">' \
            '<child xmlns:used="http://s"><used:e/></child></root>'
          )
          assert_equal('<root xmlns:unused="http://u">' \
                       '<child xmlns:used="http://s"><used:e></used:e></child></root>',
                       document.canonicalize)
          assert_equal('<root><child><used:e xmlns:used="http://s"></used:e>' \
                       '</child></root>',
                       document.canonicalize(mode: EXC))
        end

        def test_default_namespace
          document = REXML::Document.new(
            '<root xmlns="http://d"><child xmlns=""><e/></child></root>'
          )
          assert_equal('<root xmlns="http://d">' \
                       '<child xmlns=""><e></e></child></root>',
                       document.canonicalize(mode: EXC))
        end

        def test_subtree_with_cancelled_ancestor_default_namespace
          document = REXML::Document.new(
            '<root xmlns="http://default">' \
            '<child xmlns=""><grand/></child></root>'
          )
          child = document.root.elements[1]
          grand = child.elements[1]
          # Exclusive canonicalization does not import the ancestor
          # context, so at the subtree root there is no default
          # namespace left to cancel.
          assert_equal('<child><grand></grand></child>',
                       child.canonicalize(mode: EXC))
          assert_equal('<grand></grand>', grand.canonicalize(mode: EXC))
        end
      end
    end
  end
end
