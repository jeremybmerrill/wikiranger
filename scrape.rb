#!/usr/bin/env ruby
# encoding: utf-8

require 'upton'
require 'nokogiri'
require 'ipaddr'
require 'fileutils'
require 'csv'

# ignore IPs in these ranges, because there's no info there.
USELESS_ANONYMOUS_RANGES_OF_GERMAN_IPS = [
  '92.224.0.0/13',
  '78.48.0.0/13'
].map{|range| IPAddr.new(range)}

INCLUDE_NON_ANONS = true

# this class modifies Upton::Scraper
# Upton is a library for automating scraping and for automatically stashing
# pages so they're scraped only once.
# http://github.com/propublica/upton
#
class WikiEditScraper < ::Upton::Scraper
  def initialize(a, b)
    super(a, b)
    @sleep_time_between_requests = 1
    @paginated = true
    @pagination_param = "offset"
    @verbose = false
  end

  # manages pagination using Wikipedia's date-based `offset` system.
  def parse_index(text, selector)
    page = Nokogiri::HTML(text)
    if !page.css('.mw-nextlink').to_a.empty?
      @real_pagination_index = page.css('.mw-nextlink').to_a.first.attr('href').split('&').find{|snip| snip.include?('offset')}.gsub("offset=", '')
    else
      @real_pagination_index = :done
    end

    page.search(selector).to_a.map do |a_element|
      href = a_element["href"]
      resolved_url = resolve_url( href, @index_url) unless href.nil?
      resolved_url
    end
  end

  # also involved in managing pagination using Wikipedia's date-based `offset` system.
  def next_index_page_url(url, pagination_index)
    return EMPTY_STRING unless @paginated
    if @real_pagination_index.nil? || @real_pagination_index == :done
      EMPTY_STRING
    else
      uri = URI.parse(url)
      query = uri.query ? Hash[URI.decode_www_form(uri.query)] : {}
      # update the pagination query string parameter
      query[@pagination_param] = @real_pagination_index unless @real_pagination_index.nil?
      uri.query = URI.encode_www_form(query)
      uri.to_s
    end
  end

  # also involved in managing pagination using Wikipedia's date-based `offset` system.
  def get_index
    index_pages = get_index_pages(@index_url, @pagination_start_index, @pagination_interval).flatten
  end

  # also involved in managing pagination using Wikipedia's date-based `offset` system.  
  def get_index_pages(url, pagination_index, pagination_interval, options={})
    resps = [parse_index(self.get_page(url, @index_debug, options), @index_selector)]
    prev_url = url
    while !resps.last.empty?
      pagination_index += pagination_interval
      next_url = self.next_index_page_url(url, pagination_index)
      break if next_url == prev_url || next_url.empty?

      next_url = resolve_url(next_url, url)
      break if next_url == prev_url || next_url.empty?
      next_resp = self.get_page(next_url, @index_debug, options).to_s
      prev_url = next_url
      resps << parse_index(next_resp, @index_selector)
    end
    resps
  end

  # a help method to transform a Wikipedia page representing a single change
  # into an array representing the change.
  # these pages have a URL like https://en.wikipedia.org/w/index.php?title=Jeb_Bush&diff=607102701&oldid=607102655
  def self.scrape_diff_page(page, url, page_type=nil)
    date = page.css("#mw-diff-ntitle1").text.gsub("Revision as of ", '').gsub("(edit)", '').gsub("(undo)", '').gsub("Latest revision as of ", '').gsub("(view source)", '').strip
    
    #TODO: parse date

    from_ip = page.css("#mw-diff-ntitle2 .mw-#{INCLUDE_NON_ANONS ? 'userlink' : 'anonuserlink'}").text
    return nil unless from_ip.length > 0
    comment = page.css('#mw-diff-ntitle3 .comment').text.gsub("→‎", '')[1...-1] # strips parens

    results = []

    page_title = page.css('#firstHeading').text.gsub(": Difference between revisions", '')

    # gives you a brief view of what has been edited based on what type of input you gave us
    # if you gave us an IP, tell you what article was edited
    # if you gave us an article, tell you what IP edited it.
    puts "\t" + page_title if page_type == :ip
    puts "\tFrom IP: #{from_ip.inspect}" if page_type == :article 

    page.css('table.diff tr').to_a.each do |diff_row|
      next if diff_row.css('.diff-marker').to_a.empty? || diff_row.css('.diff-marker').to_a.all?{|r| r.text.match(/[\+\−]/).nil? }
      added = diff_row.css('.diff-addedline:not(:empty)')
      deleted = diff_row.css('.diff-deletedline:not(:empty)')

      added_words =   added.map{|p| (deleted.css('del').to_a.size + added.css('ins').to_a.size > 0) ? p.css('ins').to_a.map(&:text) : p.text }.reject(&:empty?)
      deleted_words = deleted.map{|p| (deleted.css('del').to_a.size + added.css('ins').to_a.size > 0) ? p.css('del').to_a.map(&:text) : p.text }.reject(&:empty?)
      next if added_words.size + deleted_words.size == 0

      count_by_ip = nil # will get added later, obvi

      begin
        if USELESS_ANONYMOUS_RANGES_OF_GERMAN_IPS.any?{|range| range.include? IPAddr.new(from_ip)}
          from_ip = 'anonymous German: ' + from_ip
        end
      rescue IPAddr::InvalidAddressError; end

      results << [page_title, url, from_ip, count_by_ip, date, comment, added_words.join(" | "), deleted_words.join(" | "), added_words.flatten.map(&:split).flatten.size + deleted_words.flatten.map(&:split).flatten.size]
    end

    results.compact!
    results.empty? ? nil : results
  end
end

# templates for Wikipedia URLs based on an IP address or a page title.
SEARCH_URL = 'https://en.wikipedia.org/w/index.php?title=Special:Contributions/<addr>'
ARTICLE_URL = 'https://en.wikipedia.org/w/index.php?title=<title>&action=history&limit=500'
if __FILE__ == $0
  # for each argument specified on the command line, process it the same way.
  ARGV.each do |page_or_cidrstr|
    begin # figure out if each arg is a cidr ip range or a wikipedia article
          # if it's not an IP range, this throws an error, sending us to the `rescue` block
      addresses = IPAddr.new(page_or_cidrstr).to_range.to_a    
      filename = "wikipedia_edits_from_#{page_or_cidrstr.gsub('/', 'slash')}.csv"

      # scrape IP address specified by the CIDR IP range (if just an IP address, scrape just that IP)
      range_or_page_data = addresses.map do |addr|
        puts addr.to_s

        diffs_scraper = WikiEditScraper.new(SEARCH_URL.gsub("<addr>", addr.to_s), # at teh URL
          "//*[contains(concat(' ', normalize-space(@class), ' '), ' mw-contributions-list ')]//a[2]") # select the link with text "(prev)"
        data = diffs_scraper.scrape do |html, url| # scrape each of the pages linked to by the links selected above.
          page = Nokogiri::HTML(html)
          WikiEditScraper.scrape_diff_page(page, url, :ip) # process each scraped page
        end
        data.flatten(1).compact # turn into an array which is sent to be written to a CSV below
      end.reject(&:empty?)

    rescue IPAddr::InvalidAddressError

      # TODO: Upton will give up if it finds an index page with nothing matching on it
      # which is bad, fix that (probably by distinguishing a nil response from an empty one?)
      # we cope with this by sending the URL of a page of 500 edits that includes anonymous edits.
      filename = "wikipedia_edits_to_#{page_or_cidrstr.gsub('/', 'slash')}.csv"


      article_name = page_or_cidrstr.to_s.gsub(" ", "_")
      # determine if we've been given an article name (e.g. "Jeb Bush") or a URL to cope with Upton bug mentioned above.
      article_url = (page_or_cidrstr.include?("http://") || page_or_cidrstr.include?("https://")) ? page_or_cidrstr : ARTICLE_URL.gsub("<title>", article_name)
      puts article_url
      diffs_scraper = WikiEditScraper.new(article_url, 
         # select the (prev) link that is in the same <li> element as an element with .mw-anonuserlink class, meaning an anonymous edit.
        "//*[@id='pagehistory']//a[contains(concat(' ', normalize-space(@class), ' '), ' mw-#{INCLUDE_NON_ANONS ? 'userlink' : 'anonuserlink'} ')]/../..//a[2]")
      range_or_page_data = diffs_scraper.scrape do |html, url| # scrape each of the pages behind the selected links
        page = Nokogiri::HTML(html) 
        WikiEditScraper.scrape_diff_page(page, url, :article) # and process each one into an array describing the edit
      end
      range_or_page_data.flatten(1).compact # and turn into the right kind of array to be written to CSV
    end

    # write our CSV.
    headers = ['page title', 'diff url', 'from IP', "days with edits from IP", 'date', 'comment', 'words added', 'words deleted', 'size of change in words']
    range_or_page_data.flatten!(1)
    range_or_page_data.compact!
    # count the number of days during which an IP made edits; a proxy for the anon editor's interest in the page.
    # if someone edits frequently, they **might** be suspiciously linked to the subject of the article.
    #                                                                                       e.g. "14:03, 22 March 2013  "
    counts_by_ip = Hash[*range_or_page_data.group_by{|i| "from ip"; i[2] }.to_a.map{|a, b| "uniq by date"; [a, b.uniq{|q| (q[4].split(/,|土/)[1] || '').strip}.size ]}.flatten]
    range_or_page_data.each{|row| row[3] = counts_by_ip[row[2]]}
    range_or_page_data.sort_by!{|row| [-row[3], row[2], row[4]] } # sort descending by counts_by_ip

    csv_data = [headers] + range_or_page_data
    if range_or_page_data.size > 0 # if there's data, write it to CSV
      CSV.open(filename, 'wb'){|f| csv_data.each{|row| f << row }}
    else                           # if there's no data, skip it and don't write a file.
      puts "skipping: #{page_or_cidrstr}"
    end

  end
end
