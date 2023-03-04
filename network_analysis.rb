#!/usr/bin/env ruby
# encoding: utf-8

require 'upton'
require 'nokogiri'
require 'ipaddr'
require 'fileutils'
require 'csv'

#TODO: ignore these, because there's no info there.
USELESS_ANONYMOUS_RANGES_OF_GERMAN_IPS = [
  '92.224.0.0/13',
  '78.48.0.0/13'
].map{|range| IPAddr.new(range)}

# "network analysis"
# in this script, I aim to find Wikipedia editors -- anonymous or not -- with an interest in editing a topic (represented by a list of pages <P>)
# by gathering all edits of <P> and, most importantly, the pages linking to <P>.
# then we just sort by the number of edits (or number of editing days, perhaps) 
# and background those editors.
# I imagine many of them will be frequent, unsuspicious Wikipedians, but I hope some will be interested editors (i.e. interestING editors)

# a future direction would be (if possible) to sort by the amount of the editor's edits that are on pages relating to the topic
# which would sort towards the top an infrequent editor who edits only pages in the topic
# and sort down a frequent Wikipedia-y Wikipedian who edits everything

class WikipediaArticle
  EDIT_HISTORY_URL = 'https://<lang>.wikipedia.org/w/index.php?title=<title>&action=history&limit=500'
  ARTICLE_URL =      'https://<lang>.wikipedia.org/wiki/<title>'
  attr_accessor :slug, :is_canonical, :language

  def initialize(url_or_slug, lang="en")
    url = (url_or_slug.include?("http://") || url_or_slug.include?("https://")) ? url_or_slug : EDIT_HISTORY_URL.gsub("<title>", url_or_slug.to_s.gsub(" ", "_")).gsub("<lang>", lang)
    @language, @slug = *url.match(/https?:\/\/(.*)\.wikipedia.org\/(?:w\/index\.php\?title=([^&]+)&|wiki\/([^?]+))/)[1..3].compact
    puts "Slug: #{@slug}"
    # @language = url.match(/https?:\/\/(.*)\.wikipedia\.org\/wiki\/.*/)[1]
    @is_canonical = nil #TODO eventually I should figure out if this URL redirects anywhere  (if it does, I think I should probably just change @url and mark @is_canonical true)
  end

  def filename_slug
    "#{@language}_#{slug}"
  end

  def edit_history_url
    EDIT_HISTORY_URL.gsub("<title>", slug).gsub("<lang>", language)
  end

  def article_url
    ARTICLE_URL.gsub("<title>", slug).gsub("<lang>", language)
  end

  def pages_linking_to
    output_slugs = []
    next_url = "https://en.wikipedia.org/w/index.php?title=Special:WhatLinksHere/#{slug}&limit=500&hidetrans=1&hideredirs=1"
    while !next_url.nil? 
      upton_resp = Upton::Downloader.new(next_url).get
      index_html = upton_resp[:resp]
      index      = Nokogiri::HTML(index_html)
      what_links_here = index.css("#mw-whatlinkshere-list a").to_a.reject{|a| a.text == "edit" || a.text == "links" || a.text.match(/^(?:User|User talk|User_talk|Wikipedia|Portal|Talk|Template|Special|Draft|File|Template talk):[^ ]/)}
      output_slugs   += what_links_here.map{|a| a.attr("href").split("/")[-1]}
      puts "#{output_slugs.size} pages linking to #{slug} so far"
      next_500_a = index.css("#mw-content-text a").to_a.find{|anchor| anchor.text == "next 500" }
      next_url = next_500_a.nil? ? nil : next_500_a.attr('href')
      next_url = (next_url.match(/^http/) ? '' : "http://#{language}.wikipedia.org" ) + next_url unless next_url.nil?
      sleep 10 if upton_resp[:from_resource]
    end
    output_slugs.map{|slug| WikipediaArticle.new(slug) }
  end

  def edits
    edit_arrays = []
    next_url = edit_history_url
    while !next_url.nil?
      puts "Next edit page URL: #{next_url}"
      upton_resp = Upton::Downloader.new(next_url).get
      edit_history_html = upton_resp[:resp]
      sleep 10 if upton_resp[:from_resource]
      edit_history      = Nokogiri::HTML(edit_history_html)
      edit_rows = edit_history.css("#pagehistory li").to_a
      edit_arrays += edit_rows.map do |row|
        diff_url = (diff_a = row.css(".mw-history-histlinks a").to_a.last).nil? ? nil : diff_a.attr('href')
        diff_url = (diff_url.match(/^http/) ? '' : "http://#{language}.wikipedia.org" ) + diff_url unless diff_url.nil?
        date_str = row.css(".mw-changeslist-date").text
        begin
          date     = Date.parse(date_str)
        rescue ArgumentError
          puts "invalid date: #{date_str.inspect}"
          date = nil
        end
        username = row.css(".mw-userlink").text
        anon     = row.css(".mw-anonuserlink").size == 0
        minor    = row.css(".minoredit").size
        article_size = row.css(".history-size").text.gsub(/\(\)/, '').gsub(" bytes", '').gsub(",",'').to_i
        diff_size = row.css(".mw-plusminus-neg, .mw-plusminus-pos").text.gsub(/\(|\)/, '').gsub(/^+/, '').to_i
        rationale = row.css(".comment").text
        [slug, diff_url, username, anon, 0, date.respond_to?(:to_date) ? date.to_date.to_s : '', rationale, diff_size]
      end
      if !edit_history.css('.mw-nextlink').to_a.empty?
        pagination_index = edit_history.css('.mw-nextlink').to_a.first.attr('href').split('&').find{|snip| snip.include?('offset')}.gsub("offset=", '')
        uri = URI.parse(next_url)
        query = uri.query ? Hash[URI.decode_www_form(uri.query)] : {}
        query["offset"] = pagination_index
        uri.query = URI.encode_www_form(query)
        next_url = uri.to_s
      else
        next_url = nil
      end
    end
    edit_arrays
  end
end

# templates for Wikipedia URLs based on an IP address or a page title.
USER_HISTORY_URL = 'https://<lang>.wikipedia.org/w/index.php?title=Special:Contributions/<addr>'

# for each argument specified on the command line, process it the same way.
# unlike scrape.rb these must be Wikipedia URLs or page names (not usernames/IPs)
base_articles = ARGV.map{ |page| WikipediaArticle.new(page) }
network = base_articles.map(&:pages_linking_to).flatten + base_articles
# TODO: ideally these could all be canonicalized (so a link to Hillary Clinton gets 301'ed to Hillary Rodham Clinton before we uniqify)
network.uniq!(&:article_url)

network_edits = network.map(&:edits)

# write our CSV.
headers = ['page title', 'diff url', 'from username', 'anon', "days with edits", 'date', 'comment', 'words added', 'words deleted', 'size of change in words']
network_edits.flatten!(1)
network_edits.compact!
# count the number of days during which an IP made edits; a proxy for the anon editor's interest in the page.
# if someone edits frequently, they **might** be suspiciously linked to the subject of the article.
intermediate_variable_for_debugging = network_edits.group_by{|i| "from username"; i[2] }.to_a.map{|a, b| "uniq by date"; [a, b.uniq{|q| q[5] }.size ]}.reject{|a, b| b <= 2}
counts_by_username = Hash[*intermediate_variable_for_debugging.flatten]
network_edits.each{|row| row[4] = counts_by_username[row[2]].to_i}
network_edits.reject!{|row| row[4].nil? || row[4] < 5}
network_edits.sort_by!{|row| [-row[4], row[2], row[5]] } # sort descending by counts_by_username, then username, then date

filename = "Wikipedia_edits_to_pages_linking_to_#{base_articles.map(&:filename_slug).join("_")}.csv"


csv_data = [headers] + network_edits
if network_edits.size > 0 # if there's data, write it to CSV
  CSV.open(filename, 'wb'){|f| csv_data.each{|row| f << row }}
else                           # if there's no data, skip it and don't write a file.
  puts "skipping (nothin' here): #{article.slug}"
end
