# frozen_string_literal: false
require_relative 'element'
require_relative 'parsers/fragmentparser'

module REXML
  class << self
    # :call-seq:
    #   REXML.parse_fragment(source, context:) -> array_of_nodes
    #
    # Parses +source+ as a stand-alone XML fragment and returns the parsed
    # nodes as an array of independent nodes (multiple sibling nodes are
    # allowed).
    #
    # +context+ is an REXML::Element whose in-scope namespaces are visible
    # to the fragment:
    #
    #   document = REXML::Document.new('<root xmlns="urn:default"/>')
    #   nodes = REXML.parse_fragment('<child/>text<!--c-->', context: document.root)
    #   nodes.first.name      # => "child"
    #   nodes.first.namespace # => "urn:default"
    #
    # Namespace declarations inside the fragment are scoped to the fragment
    # only. Prefixed names that can't be resolved against the context or a
    # fragment-local declaration raise REXML::UndefinedNamespaceException.
    #
    # Unlike REXML::Document.new, a fragment:
    #
    # - may contain several sibling elements and top-level text;
    # - may contain elements, text, comments, CDATA sections and processing
    #   instructions interleaved;
    # - must not contain an XML declaration or a DOCTYPE;
    # - must not contain an end tag that would close an element from the
    #   context.
    #
    # The context element is not modified. Parse error positions are relative
    # to the given fragment source. When the returned nodes are inserted at a
    # different place that doesn't provide the same in-scope namespaces, the
    # caller must add explicit namespace declarations; expanded names are
    # never changed by the parser.
    def parse_fragment( source, context: )
      Parsers::FragmentParser.new(source, context).parse
    end
  end
end
