module.exports = grammar({
  name: 'tree',

  extras: $ => [],

  rules: {
    document: $ => seq(
      repeat($._newline),
      repeat(seq(choice($.root, $.entry), $._newline)),
      optional(choice($.root, $.entry)),
    ),

    root: $ => '.',

    entry: $ => seq(
      repeat(choice($.guide, $._indent)),
      $.branch,
      optional(' '),
      field('path', choice($.abbreviation, $.directory, $.file)),
      optional(seq($._description_separator, field('description', $.description))),
    ),

    guide: $ => '│',

    branch: $ => choice('├─╴', '╰─╴'),

    directory: $ => /[^\s\/]+\//,

    file: $ => /[^\s\/…]+/,

    abbreviation: $ => seq(
      field('from', $.file),
      ' ',
      $.ellipsis,
      ' ',
      field('to', $.file),
    ),

    ellipsis: $ => '…',

    description: $ => /\S[^\r\n]*/,

    _indent: $ => / +/,

    _description_separator: $ => /  +/,

    _newline: $ => /\r?\n/,
  },
});
