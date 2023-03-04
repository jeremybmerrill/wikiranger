WikiRanger
===========

```
          .^.
      .._/   \-..
     / _'_ _ _'_ \
    |   W I K I   |
   | ============= |
=======================
```

This reporting tool finds politicians (and others) whose offices/associates are editing their own Wikipedia pages improperly. For instance, you can find what IP addresses frequently edit, say, likely presidential candidate Martin O'Malley's page, then look them up in WHOIS. Often, this exposes newsworthy conflicts of interest.


Usage
-----

Search wikipedia edits by specifying any of: 

- an IP address `ruby scrape.rb 192.168.0.0`
- a cidr range  `ruby scrape.rb 192.168.0.0/16`
- a wikipedia page name `ruby scrape.rb "Scott Walker (politician)"`
- a wikipedia edit history page URL* e.g. `ruby scrape.rb https://en.wikipedia.org/w/index.php?title=Special%3AWhatLinksHere&limit=500&target=Jeb+Bush&namespace=0`

This will create a spreadsheet named something like `wikipedia_edits_from_192.168.0.0.csv`. The columns in that spreadsheet are in the following format:

CSV Format
----------

#### page title
the title of the edited page
#### diff url
the URL of the edit described in this row
#### from IP
the IP address from which the page was edited
#### count from IP
the count of *distinct days* in which the page was edited by this IP address. a proxy for an IP's interest in the content of the page.
#### date
the date of the edit
#### comment
the editor's comment on the edit; frequently includes the section of the page that was edited
#### words added
the words, separated by pipes, added in this edit
#### words deleted
the words, separated by pipes, deleted in this edit
#### size of change in words
count of the words either deleted or added in this edit; where words are tokenized naively by splitting on whitespace.


Installation
------------

This requires you to have Ruby >2.0 installed.

```
git clone git@github.com:newsdev/wikiranger.git
cd wikiranger
bundle install
```

----
\* Upton has a bug where if an index page has no matching items, it will not scrape subsequent pages. Call `scrape.rb` with the URL of the first page with matching items to scrape it.


Ideas
-----
Look for edits right before big traffic (if traffic is visible). This would be someone who knows news is going to happen.
TODO: deduce interested anonymous editors of a page by finding most common anonymous editors of a page [done], AND all inbound links to that page. On the theory that a PR-conscious, ano nymous editing group would edit pages talking about their boss/client.
Sports?
JWZ viz of page length
viz of how much of NYT page was written by NYT IPs


Questions?
----------
Contact Jeremy B. Merrill
x1262
jeremy.merrill@nytimes.com
