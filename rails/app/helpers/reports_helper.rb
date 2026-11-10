# View helpers for the report pages. Class names are written out in full so Tailwind can find them.
module ReportsHelper
  REPORTS = [
    ["Income statement", "/reports/income-statement"],
    ["Balance sheet", "/reports/balance-sheet"],
    ["Trial balance", "/reports/trial-balance"],
    ["Journal", "/reports/journal"],
    ["Statistics", "/reports/statistics"],
    ["Errors", "/reports/errors"],
    ["Events", "/reports/events"],
    ["Prices", "/reports/commodities"],
  ].freeze

  # Indentation for account tree rows; "!" so it wins over the table's own cell padding.
  DEPTH_PAD = %w[pl-2! pl-6! pl-10! pl-14! pl-18! pl-22! pl-26! pl-30!].freeze

  def depth_pad(depth)
    DEPTH_PAD[[depth.to_i, DEPTH_PAD.length - 1].min]
  end

  # One "amount currency" per line; nothing for an empty (zero) map.
  def amounts(map)
    safe_join((map || {}).map { |cur, n| "#{n} #{cur}" }, tag.br)
  end

  # The same on one line; "0" for an empty (zero) map.
  def amounts_inline(map)
    map.nil? || map.empty? ? "0" : map.map { |cur, n| "#{n} #{cur}" }.join(", ")
  end

  def account_link(account, label = account)
    link_to label, "/reports/account/#{account}", class: "text-accent no-underline hover:underline"
  end

  def period_text(r)
    from, to = r["from"], r["to"]
    return "All dates" if from.nil? && to.nil?
    return "Up to and including #{to}" if from.nil?
    return "From #{from} on" if to.nil?
    "From #{from} to #{to}"
  end

  # Quick period choices: [label, query string].
  def period_links(show_from)
    t = Date.today
    month_end = Date.new(t.year, t.month, -1)
    last_month_end = Date.new(t.year, t.month, 1) - 1
    if show_from
      [["All dates", ""],
       ["This year", "?from=#{t.year}-01-01&to=#{t.year}-12-31"],
       ["Last year", "?from=#{t.year - 1}-01-01&to=#{t.year - 1}-12-31"],
       ["This month", "?from=#{t.strftime('%Y-%m-01')}&to=#{month_end.iso8601}"],
       ["Last month", "?from=#{last_month_end.strftime('%Y-%m-01')}&to=#{last_month_end.iso8601}"]]
    else
      [["Everything", ""], ["End of last month", "?to=#{last_month_end.iso8601}"], ["End of last year", "?to=#{t.year - 1}-12-31"]]
    end
  end
end
