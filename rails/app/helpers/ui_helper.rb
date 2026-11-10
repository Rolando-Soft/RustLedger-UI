# Tailwind class lists used by more than one element. The layout hands the same lists to the page's
# script as JSON (#ui-classes), so markup built in JavaScript looks the same as markup in the view.
# Keep every class written out in full here: Tailwind finds classes by reading this file.
module UiHelper
  UI = {
    label: "block text-[.8rem] opacity-75 mb-0.5",
    field: "px-2 py-1.5 border border-line rounded-md max-sm:text-[16px] max-sm:min-h-[42px]",
    field_small: "px-1.5 py-[3px] border border-line rounded-md max-sm:text-[16px] max-sm:min-h-[42px]",
    btn: "px-3.5 py-[7px] rounded-md border border-line cursor-pointer disabled:opacity-45 disabled:cursor-default max-sm:min-h-[42px] max-sm:py-2",
    primary: "px-3.5 py-[7px] rounded-md border border-accent bg-accent text-white cursor-pointer disabled:opacity-45 disabled:cursor-default max-sm:min-h-[42px] max-sm:py-2",
    banner_btn: "px-3.5 py-[7px] rounded-md border border-line cursor-pointer max-sm:min-h-[38px] max-sm:py-2",
    nav: "px-3.5 py-[7px] rounded-md border border-line cursor-pointer max-sm:flex-auto max-sm:px-1.5 max-sm:py-2 max-sm:text-[.9rem] max-sm:min-h-[42px] [&.active]:bg-accent [&.active]:border-accent [&.active]:text-white",
    pill: "px-2.5 py-0.5 rounded-full text-[.8rem] border border-line cursor-pointer disabled:opacity-45 disabled:cursor-default max-sm:min-h-[42px] [&.armed]:bg-bad [&.armed]:border-bad [&.armed]:text-white",
    chip: "px-2.5 py-1 rounded-full text-[.85rem] border border-line cursor-pointer max-sm:min-h-[34px] [&.active]:bg-accent [&.active]:border-accent [&.active]:text-white",
    chip_search: "px-2 py-1.5 border border-line rounded-md ml-auto min-w-[180px] max-sm:text-[16px] max-sm:min-h-[42px] max-sm:ml-0 max-sm:min-w-0 max-sm:w-full",
    posting_row: "grid grid-cols-[56px_1fr_130px_80px_30px] gap-2 mb-2 max-sm:grid-cols-[64px_1fr_84px_60px_42px] max-sm:gap-1.5",
    close_box: "flex gap-2 items-center flex-wrap mt-2 whitespace-normal text-[CanvasText]",
    status: "my-2.5 min-h-[1.4em] text-[.9rem] whitespace-pre-wrap data-[tone=ok]:text-ok data-[tone=bad]:text-bad data-[tone=muted]:opacity-70",
    pre: "bg-tint border border-line rounded-md p-2.5 overflow-x-auto m-0 min-h-[calc(3.5em+22px)]",
    table: "w-full text-[.85rem] [&_td]:px-2 [&_td]:py-1 [&_td]:border-b [&_td]:border-line [&_td]:align-top [&_td.num]:text-right [&_td.num]:tabular-nums [&_.muted]:opacity-70 [&_a.lnk]:text-accent [&_a.lnk]:no-underline [&_a.lnk:hover]:underline max-sm:block max-sm:overflow-x-auto max-sm:whitespace-nowrap max-sm:[&_td]:px-1.5 max-sm:[&_td]:py-1.5",
    combo: "absolute left-0 top-full z-10 max-h-[280px] overflow-y-auto mt-0.5 bg-[Canvas] text-[CanvasText] border border-line rounded-md shadow-[0_6px_18px_#0003] max-sm:max-h-[50vh] [&_.opt]:cursor-pointer [&_.opt.active]:bg-accent [&_.opt.active]:text-white [&_.opt_b]:underline [&_.none]:px-[9px] [&_.none]:py-[5px] [&_.none]:opacity-60",
    row: "flex flex-wrap items-end gap-2.5 mb-3 max-sm:gap-3 max-sm:mb-2",
    cell: "flex-1 min-w-[120px] max-sm:flex-[1_1_100%] max-sm:min-w-0 max-sm:w-full",
    cell_2: "flex-[2] min-w-[120px] max-sm:flex-[1_1_100%] max-sm:min-w-0 max-sm:w-full",
    cell_110: "flex-[0_0_110px] min-w-[120px] max-sm:flex-[1_1_100%] max-sm:min-w-0 max-sm:w-full",
    cell_150: "flex-[0_0_150px] min-w-[120px] max-sm:flex-[1_1_100%] max-sm:min-w-0 max-sm:w-full",
    cell_170: "flex-[0_0_170px] min-w-[120px] max-sm:flex-[1_1_100%] max-sm:min-w-0 max-sm:w-full",
    cell_190: "flex-[0_0_190px] min-w-[120px] max-sm:flex-[1_1_100%] max-sm:min-w-0 max-sm:w-full",
    cell_auto: "flex-[0_0_auto] min-w-[120px] max-sm:flex-[1_1_100%] max-sm:min-w-0 max-sm:w-full",
    h1: "text-[1.3rem] font-bold my-[.67em] max-sm:text-[1.2rem]",
    h2: "text-base font-bold mt-8 mb-[.83em] max-sm:mt-6",
    h2_tight: "text-base font-bold mt-2 mb-[.83em]",
    hint: "opacity-70 text-[.85rem]",
  }.freeze

  def ui(*names)
    names.map { |n| UI.fetch(n) }.join(" ")
  end
end
