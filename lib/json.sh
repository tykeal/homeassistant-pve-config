#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# The one hardened JSON decoder this toolkit reads hosts with.
#
# JSON is decoded by perl, not by this shell. The parser that used to live
# in lib/acme.sh split on commas and stopped at the first `]`, so a string
# holding either one moved every field after it. That is not a corner
# case: an issuer DN is full of commas. Worse, the three-valued answer
# every reader here gives rests on knowing the difference between "the
# host says no" and "this code could not read the answer", and a parser
# that silently reads the wrong field cannot tell them apart.
#
# perl with JSON::PP is a core module, and Proxmox itself is written in
# perl, so this adds nothing to what a PVE host already carries. The
# programs built from the pieces below are constants: the document arrives
# on standard input and the parameters arrive in @ARGV, so nothing from
# the host is ever interpolated into code.
#
# Exit status is the contract, everywhere it is used:
#   0  the answer was read, and is on standard output
#   1  the document was read and does not have it
#   2  anything else, including a document that will not decode, a field
#      of the wrong shape, and a perl that is not there at all
#
# Why one core and not three programs. lib/acme.sh, lib/tailscale.sh and
# lib/haos.sh each used to carry a whole decoder, hardened separately
# across separate review rounds. The reasons recorded for the split were
# real but they were reasons for *different access patterns*, not for
# three copies of the byte handling: reading the document as raw bytes,
# refusing bytes that are not UTF-8, refusing a document that is empty or
# only whitespace, deciding a value's shape by re-encoding it rather than
# by stringifying it, and refusing control characters in anything emitted.
# Those are the security-relevant parts, and three copies of them is three
# places a fix can be applied to two. They live here once.
#
# What is still not shared, deliberately:
#
#   * The modes. Each library concatenates its own dispatch onto this
#     core, so the decoder the ACME secret path runs still understands
#     scalar/names/entry and nothing else. A mode is reachable only from
#     the program that declares it, which is what the old comments were
#     protecting when they said not to widen acme's decoder for the
#     benefit of a stage that does not share its threat model.
#   * Refusing a duplicated key. Only lib/tailscale.sh needs it, and it
#     costs a lexer over the raw text because JSON::PP keeps the last of
#     a repeated key and offers no allow_dupkeys. It stays with the one
#     mode that asks for it.

# The shared core. Everything above the mode dispatch: the document, its
# validation, and the two subs every mode emits through.
read -r -d '' _JSON_DECODER_CORE <<'PERL' || true
use strict;
use warnings;
use JSON::PP ();

my $mode = shift @ARGV;
exit 2 unless defined $mode;

# The document is read as bytes. That is what lets a NUL byte, or a
# sequence that is not UTF-8 at all, be seen and refused here: a NUL that
# travelled through a shell variable on its way would have been dropped
# silently, and the text either side of it would have been joined into a
# value nobody sent.
binmode STDIN, ':raw';
binmode STDOUT, ':utf8';
my $raw = do { local $/; <STDIN> };
# Each of these three is reached, and each is also behaviourally
# redundant: an empty document, a whitespace-only one and one that is
# not UTF-8 all fail the decode below as well, so removing any of them
# still answers 2. They are defence in depth, not load-bearing -- kept
# because a document that never reaches a parser is the cheapest kind to
# refuse, and because the decode is the part most likely to be swapped.
# Do not read "redundant" as "dead": they do run.
exit 2 unless defined $raw && length $raw;
exit 2 unless utf8::decode($raw);
exit 2 unless $raw =~ /\S/;

my $data = eval { JSON::PP->new->decode($raw) };
exit 2 if $@ or !defined $data;

# A JSON string, and nothing else.
#
# null, a number, a boolean and a structure are each refused where a
# string is required, because each of them has a stringification that
# reads like an answer -- the empty string for null, the digits for a
# number -- and would then be compared against a directory, an issuer or
# a filename as though the host had said it. Re-encoding is how the shape
# is decided, since by this point perl has only a scalar either way.
my $probe = JSON::PP->new->allow_nonref;

sub text {
    my ($value) = @_;
    # Reached, and redundant the same way: a JSON null arrives as undef
    # and the re-encode below refuses it too, since "null" does not open
    # with a quote. It is kept so the three refusals read in the order a
    # reader expects, not because it is the only thing standing between
    # a null and an answer.
    exit 2 unless defined $value;
    exit 2 if ref $value;
    exit 2 unless $probe->encode($value) =~ /\A"/;
    return $value;
}

# Only printable scalars leave here. A control character in a value would
# be read back as a line of its own by the caller.
sub emit {
    my (@parts) = @_;
    for my $part (@parts) {
        exit 2 if $part =~ /[\x00-\x1f\x7f]/;
    }
    print join("\t", @parts), "\n";
}
PERL

# Walking the cluster resource listing, which lib/tailscale.sh and
# lib/haos.sh both do. They read the same document and differ only in
# which guest type they are looking for, so the walk is one piece of code
# and the type is a parameter of it.
read -r -d '' _JSON_DECODER_GUESTS <<'PERL' || true
# A listing entry has to name a guest id, and name it with something that
# reads as one. An entry that does not is a listing this code cannot
# answer from, including about the guests it does describe.
sub guest_vmid {
    my ($item) = @_;
    exit 2 unless exists $item->{vmid};
    my $vmid = $item->{vmid};
    exit 2 if !defined $vmid || ref $vmid;
    exit 2 unless "$vmid" =~ /\A[0-9]+\z/;
    return "$vmid";
}

sub guest_node {
    my ($item) = @_;
    return exists $item->{node} ? text($item->{node}) : '';
}

sub tagged_guests {
    my ($data, $want, $tag) = @_;
    exit 2 unless defined $tag && length $tag;
    exit 2 unless ref $data eq 'ARRAY';
    my $found = 0;
    for my $item (@$data) {
        exit 2 unless ref $item eq 'HASH';
        # A listing entry with no type is a listing this code cannot
        # answer from, including about the guests it does describe.
        exit 2 unless exists $item->{type};
        next unless text($item->{type}) eq $want;
        my $vmid = guest_vmid($item);
        # tags is absent on an untagged guest, which is a guest that is
        # certainly not this toolkit's.
        next unless exists $item->{tags};
        my @tags = split /[;, ]+/, text($item->{tags});
        next unless grep { $_ eq $tag } @tags;
        emit($vmid, guest_node($item));
        $found = 1;
    }
    exit 1 unless $found;
}

sub cluster_ids {
    my ($data) = @_;
    exit 2 unless ref $data eq 'ARRAY';
    my $found = 0;
    for my $item (@$data) {
        exit 2 unless ref $item eq 'HASH';
        exit 2 unless exists $item->{type};
        my $type = text($item->{type});
        next unless $type eq 'lxc' || $type eq 'qemu';
        my $vmid = guest_vmid($item);
        emit($vmid, $type, guest_node($item));
        $found = 1;
    }
    exit 1 unless $found;
}
PERL

# Joins the core to a library's own pieces: whichever shared walks it
# uses, then its own mode dispatch. Newlines between them, because `read`
# strips the trailing one off each.
_json_program() {
  local fragment
  printf '%s\n' "${_JSON_DECODER_CORE}"
  for fragment in "$@"; do
    printf '%s\n' "${fragment}"
  done
}

# Runs a command and decodes what it printed.
#
# The output goes from the command to perl through a pipe and never
# through a shell variable. A variable cannot hold a NUL byte: bash drops
# it, and the text either side closes up, so an issuer of
# "O=(STAGING) Let's Encrypt\0 and friends" would arrive at the issuer
# check as the exact string the check accepts. On the pipe the byte
# survives to be refused.
#
# The arguments are the program, then the decoder's parameters, then --,
# then the command. Nothing the host said is ever an argument of the
# decoder, and the command itself -- a plugin configuration carries the
# encoded credentials -- prints to the pipe rather than into anything
# readable from /proc.
#
#   0  the field was read, and is on standard output
#   1  the document was read and does not have it
#   2  anything else, including a command that failed, a document that
#      will not decode, and a field of the wrong shape
_json_decode_cmd() {
  local program=$1
  shift
  local arg seen=0
  local -a params=() cmd=()
  for arg in "$@"; do
    if ((seen)); then
      cmd+=("${arg}")
    elif [[ ${arg} == '--' ]]; then
      seen=1
    else
      params+=("${arg}")
    fi
  done
  ((seen)) || return 2
  ((${#cmd[@]} > 0)) || return 2

  local captured states source_status decode_status
  captured=$(
    # Without this the pipeline's failure would end the subshell under
    # `set -e` before either status could be reported.
    set +e
    "${cmd[@]}" 2>/dev/null |
      perl -e "${program}" -- ${params[@]+"${params[@]}"} 2>/dev/null
    printf '\n%s' "${PIPESTATUS[*]}"
  )
  states=${captured##*$'\n'}
  captured=${captured%$'\n'*}
  source_status=${states%% *}
  decode_status=${states##* }
  [[ ${source_status} == 0 ]] || return 2
  while [[ ${captured} == *$'\n' ]]; do
    captured=${captured%$'\n'}
  done
  case ${decode_status} in
    0) printf '%s' "${captured}" ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# The decoder, checked once and by name.
#
# Without it every reading of a host's answer returns "I could not tell",
# which stops the stage with a message about something unreadable -- true,
# and unhelpful. JSON::PP is a core module, and Debian keeps the core
# modules in perl-modules rather than perl-base, so the one host that
# could lack it is one stripped down to the essential package set.
json_require_decoder() {
  perl -MJSON::PP -e 'exit 0' >/dev/null 2>&1 ||
    die 'This stage reads what pvenode reports with perl and JSON::PP, and one of them is missing. Install the perl package (JSON::PP ships with the core modules, not with perl-base).'
}
