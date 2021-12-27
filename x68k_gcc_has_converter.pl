﻿#!/usr/bin/perl
#------------------------------------------------------------------------------
#
#	x68k_gcc_has_converter
#
#	JP:
# 		m68k-elf-gcc が生成した asm ソースを、HAS.X (X68K High-speed Assembler
#		by Y.Nakamura(YuNK)) が処理できる形式に変換します。
#
#	EN:
#		This is a converter translates asm sources generated by m68k-elf-gcc
#		into a format that processible by HAS.X (X68K High-Speed Assembler by
#		Y.Nakamura(YuNK)).
#
#------------------------------------------------------------------------------
#
#	Copyright (C) 2021 Yosshin(@yosshin4004)
#
#	Licensed under the Apache License, Version 2.0 (the "License");
#	you may not use this file except in compliance with the License.
#	You may obtain a copy of the License at
#
#	    http://www.apache.org/licenses/LICENSE-2.0
#
#	Unless required by applicable law or agreed to in writing, software
#	distributed under the License is distributed on an "AS IS" BASIS,
#	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#	See the License for the specific language governing permissions and
#	limitations under the License.
#
#------------------------------------------------------------------------------

# コーディングを厳格化
use strict;

# 使用するモジュール
use IO::File;

# 定数の定義
use constant {
    EXIT_SUCCESS	=> 0,
    EXIT_FAILURE	=> 1,
	DEBUG	 		=> 0,	# 0 or 1
};

# 10 進数または 16 進数にマッチする正規表現
#	16 進数冒頭の 0x が 10 進数の一部と認識されること等を避けるため、
#	後続が a-zA-Z_ でない場合のみ 10 進数と判定している。
my $g_regex_dec_or_hex	= '(?:\\d+(?![a-zA-Z_])|0x[0-9a-fA-F]+)';

# 数値またはラベル名または式にマッチする正規表現
my $g_regex_expression	= '[a-zA-Z0-9_.\\+\\-]+';


# 各種オペランドサイズにマッチする正規表現
#	.b .w .l のように、ドットを使う表記だけでなく、
#	:b :w :l のような、コロンを使う表記が出現することがある点に注意。
my $g_regex_opsize = '[:.][bwl]';

# ビットフィールド（-m68030 指定時に出現）にマッチする正規表現
#	例:
#		{1:2}
#		{#1:#2}
#	参考:
#		https://stdkmd.net/bitfield/
my $g_regex_bitfield = '\\{(?:\\#)?\\d+\\:(?:\\#)?\\d+\\}';

# 各種レジスタにマッチする正規表現
#	a6 を意味する fp と fp0-fp7 は誤認識される危険があるので評価順に注意すること。
#	参考:
#		http://yamatyuu.net/computer/68000/index.html
my $g_regex_dn		= "%d[0-7](?:$g_regex_opsize)?(?:$g_regex_bitfield)?";
my $g_regex_an		= "(?:%a[0-7]|%fp|%sp)(?:$g_regex_opsize)?(?:$g_regex_bitfield)?";
my $g_regex_sr		= "%sr(?:$g_regex_bitfield)?";
my $g_regex_ccr		= "%ccr(?:$g_regex_bitfield)?";
my $g_regex_fpn		= "(?:%fp[0-7])";
my $g_regex_fpcr	= "%fpcr(?:$g_regex_bitfield)?";
my $g_regex_fpsr	= "%fpsr(?:$g_regex_bitfield)?";
my $g_regex_fpiar	= "%fpiar(?:$g_regex_bitfield)?";

# dn:dn（-m68030 指定時に出現）にマッチする正規表現
my $g_regex_dn_dn	= "$g_regex_dn\\:$g_regex_dn";

# ix にマッチする正規表現
my $g_regex_ix =
	"(?:"
.		"(?:"
.			 "$g_regex_dn"
.			"|$g_regex_an"
.		")"
.		"(?:"
.			"\\*\\d+"	# スケールの指定（-m68030 指定時に出現）
.		")?"
.	")";

# 全レジスタにマッチする正規表現
my $g_regex_register =
	"(?:"
.		 "$g_regex_dn_dn"
.		"|$g_regex_dn"		# dn:dn にマッチしてしまうので最後に評価する。
.		"|$g_regex_sr"
.		"|$g_regex_ccr"
.		"|$g_regex_fpn"
.		"|$g_regex_fpcr"
.		"|$g_regex_fpsr"
.		"|$g_regex_fpiar"
.		"|$g_regex_an"		# fp0-fp7 に a6 の別名の fp がマッチしてしまうので最後に評価する。
.	")";

# 引数解析～コンバータ適用
{
	# 引数解析結果
	my $input_file_name;
	my $output_file_name;
	my $cpu_type = '68000';

	# 引数カウント
	my $argc = $#ARGV + 1;

	# 引数なしで起動した場合はヘルプを表示して終了
	if ($argc == 0) {
		print	''
		."\n".	'x68k_gcc_has_converter'
		."\n".	'Copyright (C) 2021 Yosshin(@yosshin4004)'
		."\n".	''
		."\n".	'This is a converter translates asm sources generated by m68k-elf-gcc'
		."\n".	'into a format that processible by HAS.X (X68K High-Speed Assembler by'
		."\n".	'Y.Nakamura(YuNK)).'
		."\n".	''
		."\n".	'[usage]'
		."\n".	'	perl x68k_gcc_has_converter.pl [options]'
		."\n".	''
		."\n".	'	options:'
		."\n".	'		-i <input filename>'
		."\n".	'		-o <output filename>'
		."\n".	'		-cpu <CPU type (default is 68000)>'
		."\n".	''
		."\n";
		exit(EXIT_SUCCESS);
	}

	# オプション解析
	my $iArg = 0;
	while ($iArg < $argc) {
		# オプション指定を検出
		if ($ARGV[$iArg] =~ /^-/) {
			# 入力ファイル指定？
			if ($ARGV[$iArg] eq "-i") {
				# 引数取得
				$iArg++;
				if ($iArg >= $argc) {
					print "ERROR : Argument for " . $ARGV[$iArg - 1] . " is not specified.\n";
					exit(EXIT_FAILURE);
				}
				$input_file_name = $ARGV[$iArg];
			}
			# 出力ファイル指定？
			elsif ($ARGV[$iArg] eq "-o") {
				# 引数取得
				$iArg++;
				if ($iArg >= $argc) {
					print "ERROR : Argument for " . $ARGV[$iArg - 1] . " is not specified.\n";
					exit(EXIT_FAILURE);
				}
				$output_file_name = $ARGV[$iArg];
			}
			# CPU タイプ指定？
			elsif ($ARGV[$iArg] eq "-cpu") {
				# 引数取得
				$iArg++;
				if ($iArg >= $argc) {
					print "ERROR : Argument for " . $ARGV[$iArg - 1] . " is not specified.\n";
					exit(EXIT_FAILURE);
				}
				$cpu_type = $ARGV[$iArg];
			}
			# いずれも該当しないなら不正な引数
			else {
				print "ERROR : Invalid option " . $ARGV[$iArg] . " is specified.\n";
				exit(EXIT_FAILURE);
			}
		} else {
			# 不正な引数
			print "ERROR : Invalid option " . $ARGV[$iArg] . " is specified.\n";
			exit(EXIT_FAILURE);
		}

		# 次の要素へ
		$iArg++;
	}

	# 引数が足りないならエラー
	if ($input_file_name eq '') {
		print "ERROR : Input filename is not specified.\n";
		exit(EXIT_FAILURE);
	}
	if ($output_file_name eq '') {
		print "ERROR : Output filename is not specified.\n";
		exit(EXIT_FAILURE);
	}

	# コンバータ本体実行
	apply_converter($input_file_name, $output_file_name, $cpu_type);
}

exit(EXIT_SUCCESS);



#------------------------------------------------------------------------------
#	コンバータを適用する
#
#	[parameters]
#		・$input_file_name
#			入力ファイル名
#
#		・$output_file_name
#			出力ファイル名
#
#		・$cpu_type
#			CPU タイプ
#
#	[return]
#		なし
#------------------------------------------------------------------------------
sub apply_converter {
	my (
		$input_file_name,
		$output_file_name,
		$cpu_type,
	) = @_;

	my $fh_input  = IO::File->new($input_file_name,  'r') or die("ERROR : Cannot open [" . $input_file_name  . "].\n");
	my $fh_output = IO::File->new($output_file_name, 'w') or die("ERROR : Cannot open [" . $output_file_name . "].\n");

	# 入力ファイル全体を一行ずつ修正
	my $line;
	my $line_num;
	while ($line = <$fh_input>) {
		$line_num++;
		my $src_location = $input_file_name . ':' . $line_num;

		chomp($line);
		my $orig = $line;

		# 修正結果の生成先
		my $modified;

		# ラベル行？
		#	m68k_gcc
		#		abc:
		#	HAS
		#		_abc:
		#
		# 行頭から始まり : で終わる文字列をラベルと認識する。
		if ($line =~ /^([a-zA-Z_?.].*)\:/) {
			my $label = $1;
			$modified = modify_label($label, $src_location) . ':';
		}
		# ディレクティブ行？
		elsif ($line =~ /^\s+\./) {
			# バイナリ埋め込みの修正
			#	m68k_gcc
			#		.long	123, ...
			#		.word	123, ...
			#		.byte	123, ...
			#	HAS
			#		.dc.l	123, ...
			#		.dc.w	123, ...
			#		.dc.b	123, ...
			if ($line =~ /^\s+\.long\s+(.*)/) {
				my $param = $1;
				$modified = '	.dc.l ' . modify_args($param, $src_location);
			}
			elsif ($line =~ /^\s+\.word\s+(.*)/) {
				my $param = $1;
				$modified = '	.dc.w ' . modify_args($param, $src_location);
			}
			elsif ($line =~ /^\s+\.byte\s+(.*)/) {
				my $param = $1;
				$modified = '	.dc.b ' . modify_args($param, $src_location);
			}
			# 文字列リテラルの修正
			#	m68k_gcc
			#		.string	"ABC"
			#	HAS
			#		.dc.b $41,$42,$43,$00	（末端に \0 が付加される）
			elsif ($line =~ /^\s+\.string\s+\"(.*)\"/) {
				my $string	= $1;
				$modified = convert_string_to_dump($string);
			}
			# 文字列リテラルの修正
			#	m68k_gcc
			#		.ascii "\b\007\009"
			#	HAS
			#		.dc.b $08,$07,$09	（末端に \0 が付加されない）
			elsif ($line =~ /^\s+\.ascii\s+\"(.*)\"/) {
				my $string	= $1;
				$modified = convert_ascii_to_dump($string);
			}
			# .globl ディレクティブで指定されているラベル
			#	m68k_gcc
			#		.globl inflateBackInit_
			#	HAS
			#		.globl _inflateBackInit_
			elsif ($line =~ /\s+\.globl\s+(.*)/) {
				my $label = $1;
				$modified = '	.globl ' . modify_label($label, $src_location);
			}
			# .comm ディレクティブ
			#	m68k_gcc
			#			.comm	LOCTBL_TOP,16,2
			#	HAS
			#			.comm	LOCTBL_TOP,16
			elsif ($line =~ /\s+\.comm\s+(.*),($g_regex_dec_or_hex),($g_regex_dec_or_hex)/) {
				my $label = $1;
				my $size  = $2;
				my $align = $3;
				$modified =
					'	.align ' . $align . "\n"
				.	'	.comm ' . modify_label($label, $src_location) . ',' . $size;
			}
			# .zero ディレクティブ
			#	m68k_gcc
			#		.zero	123
			#	HAS
			#		.ds.b	16
			elsif ($line =~ /\s+\.zero\s+($g_regex_dec_or_hex)/) {
				my $size = $1;
				$modified = '	.ds.b ' . $size;
			}
			# 読み取り専用データ
			#	m68k_gcc
			#		.section	.rodata
			#		.section	.rodata.str1.1
			#		等々
			#	HAS
			#		.data
			elsif ($line =~ /\s+\.section\s+\.rodata/) {
				$modified = '	.data';
			}
			# BSS セクション
			#	m68k_gcc
			#		.section	.bss
			#	HAS
			#		.bss
			elsif ($line =~ /\s+\.section\s+\.bss/) {
				$modified = '	.bss';
			}
			# HAS が認識できないディレクティブの除去
			#	.local		static なシンボル
			#	.type		ラベルの用途を指定するデバッグ情報らしい
			#	.size		詳細不明
			#	.ident		コンパイラのバージョン情報らしい
			#	.section	必要なものは個別に認識済み
			#	.swbeg		詳細不明
			#	.cfi_...	デバッグ情報らしい
			elsif ($line =~ /^\s+\.(local\s+|type\s+|size\s+|ident\s+|section\s+|swbeg\s+|cfi_\w+\s+)/) {
			}
			# アライメントの指定を修正
			#	m68k_gcc
			#		.balignw 2,0x284c
			#	HAS
			#		.align 2
			#
			# m68k_gcc では、アライメントで発生するパディングの値を
			# 指定できるようだが、該当する機能が HAS には存在しない。
			# .align で代用する。
			elsif ($line =~ /^\s+\.balignw\s+($g_regex_dec_or_hex),(.*)/) {
				my $align	= $1;
				my $padding	= $2;
				$modified = '	.align ' . $align;
			}
			# 上記いずれにも該当しないなら変更不要
			else {
				$modified = $line;
			}
		} else {
			# movem 命令（制御・可変モード）のレジスタ指定
			#	m68k_gcc
			#		movem.l #15360,(sp)
			#	HAS
			#		movem.l d3/d4/d5/a3/a4,(sp)
			if ($line =~ /(^\s+movem\.\w)\s+\#($g_regex_dec_or_hex),([^-].*)/) {
				my $op		= $1;
				my $mask	= $2;
				my $dst		= $3;
				$modified = $op . ' ' . convert_movem_mask_to_reg_list($mask) . ',' . $dst;
			}
			# movem 命令（プレデクリメントモード）のレジスタ指定
			#	m68k_gcc
			#		movem.l #15360,-(sp)
			#	HAS
			#		movem.l d3/d4/d5/a3/a4,-(sp)
			elsif ($line =~ /(^\s+movem\.\w)\s+\#($g_regex_dec_or_hex),(-.*)/) {
				my $op		= $1;
				my $mask	= $2;
				my $dst		= $3;
				$modified = $op . ' ' . convert_movem_mask_to_reg_list(reverse_movem_mask($mask)) . ',' . $dst;
			}
			# movem 命令のレジスタ指定
			#	m68k_gcc
			#		movem.l (sp)+,#1148
			#	HAS
			#		movem.l (sp)+,d2/d3/d4/d5/d6/a2
			elsif ($line =~ /(^\s+movem\.\w)\s+(.*),\#($g_regex_dec_or_hex)/) {
				my $op		= $1;
				my $src		= $2;
				my $mask	= $3;
				$modified = $op . ' ' . $src . ',' . convert_movem_mask_to_reg_list($mask);
			}
			# jXX 命令
			#	m68k_gcc
			#		jhi		jls		jcc		jcs		jne		jeq		jvc
			#		jvs		jpl		jmi		jge		jlt		jgt		jle
			#		jra
			#	HAS
			#		jbhi	jbls	jbcc	jbcs	jbne	jbeq	jbvc
			#		jbvs	jbpl	jbmi	jbge	jblt	jbgt	jble
			#		jbra
			#
			# HAS では、jcc と bcc を自動選択できる jbcc が使える。
			elsif ($line =~ /^\s+j(hi|ls|cc|cs|ne|eq|vc|vs|pl|mi|ge|lt|gt|le|ra)\s+(.*)/) {
				my $condition	= $1;
				my $dst			= $2;
				$modified = '	jb' . $condition . ' ' . modify_args($dst, $src_location);
			}
			# jsr 命令
			#	m68k_gcc
			#		jsr
			#	HAS
			#		jbra
			#
			# HAS では、jsr と bsr を自動選択できる jbsr が使える。
			elsif ($line =~ /^\s+jsr\s+(.*)/) {
				my $dst = $1;
				$modified = '	jbsr ' . modify_args($dst, $src_location);
			}
			# その他の命令
			#
			# 命令自体は変換不要だが、オペランドは修正する必要がある。
			elsif ($line =~ /^\s+(.+)\s+(.*)$/) {
				my $op		= $1;
				my $args	= $2;
				$modified = '	' . $op . ' ' . modify_args($args, $src_location);
			}
			# 冒頭の定型句の修正
			elsif ($line =~ /^#NO_APP$/) {
				$modified = '* NO_APP'
					."\n".	'RUNS_HUMAN_VERSION	equ	3'
					."\n".	'	.cpu ' . $cpu_type
					."\n".	'* X68 GCC Develop'
					."\n";
			}
			# 上記いずれにも該当しないなら変更不要
			else {
				$modified = $line;
			}
		}

		# レジスタの表記を修正
		#	m68k_gcc
		#		%fp0-%fp7
		#		%d0-%d7 %a0-%a7 %sp %fp %ccr %sr %fpcr %fpsr %fpiar
		#		%d0:l %d1:w %d2:b （. でなく : であることに注意。pc 相対の ix として出現する）
		#	HAS
		#		fp0-fp7
		#		d0-d7 a0-a7 sp a6 ccr sr fpcr fpsr fpiar
		#		d0.l d1.w d2.b
		$modified =~ s/%(fp[0-7])/\1/g;
		$modified =~ s/%fpcr/fpcr/g;
		$modified =~ s/%fpsr/fpsr/g;
		$modified =~ s/%fpiar/fpiar/g;
		$modified =~ s/%(d[0-7])\:([bwl])/\1.\2/g;
		$modified =~ s/%(a[0-7])\:([bwl])/\1.\2/g;
		$modified =~ s/%(d[0-7])/\1/g;
		$modified =~ s/%(a[0-7])/\1/g;
		$modified =~ s/%sp/sp/g;
		$modified =~ s/%fp/a6/g;		# 浮動小数レジスタの一部と認識されることを避けるため最後に置換する
		$modified =~ s/%pc/pc/g;
		$modified =~ s/%ccr/ccr/g;
		$modified =~ s/%sr/sr/g;

		# 変換前の記述をコメント行として付加
		{
			# TAB 整形
			my $columns = calc_columns($modified);
			while ($columns < 48) {
				$columns += 8;
				$modified .= '	';
			}
			$modified .= '	*' . $orig
		}

		# 1行出力
		print $fh_output $modified . "\n";
	}

	$fh_output->close;
	$fh_input ->close;
}


#------------------------------------------------------------------------------
#	movem 命令のレジスタマスク値にビット並びを反転する
#
#	[parameters]
#		・$mask
#			レジスタマスク値
#
#	[return]
#		レジスタマスク値のビット並び反転結果
#------------------------------------------------------------------------------
sub reverse_movem_mask {
	my (
		$mask
	) = @_;
	my $reverse_mask = 0;
	for (my $i = 0; $i < 16; $i++) {
		if ($mask & (1 << (15 - $i))) {
			$reverse_mask |= 1 << $i;
		}
	}
	return $reverse_mask;
}


#------------------------------------------------------------------------------
#	movem 命令のレジスタマスク値を HAS スタイルのレジスタリストに変換
#
#	[parameters]
#		・$mask
#			レジスタマスク値
#
#	[return]
#		HAS スタイルのレジスタリスト
#------------------------------------------------------------------------------
sub convert_movem_mask_to_reg_list {
	my (
		$mask
	) = @_;
	my $reg_list;
	for (my $i = 0; $i < 16; $i++) {
		if ($mask & (1 << $i)) {
			if ($reg_list ne ''){ $reg_list .= '/' ;}
			if ($i < 8) {
				$reg_list .= 'd' . ($i & 7);
			} else {
				$reg_list .= 'a' . ($i & 7);
			}
		}
	}
	return $reg_list;
}


#------------------------------------------------------------------------------
#	ラベルを HAS スタイルに修正する
#
#	[parameters]
#		・$label
#			ラベル
#
#		・$src_location
#			ソースの位置情報
#
#	[return]
#		HAS スタイルのラベル
#------------------------------------------------------------------------------
sub modify_label {
	my (
		$label,
		$src_location
	) = @_;
	$label =~ s/\./\?/g;
	return '_' . $label;
}


#------------------------------------------------------------------------------
#	ラベル交じりの式を HAS スタイルに修正する
#
#	[parameters]
#		・$expression
#			ラベル交じりの式
#
#		・$src_location
#			ソースの位置情報
#
#	[return]
#		HAS スタイルの式
#------------------------------------------------------------------------------
sub modify_expression {
	my (
		$expression,
		$src_location
	) = @_;

	my $input = $expression;
	my @a_term;

	# 分解と修正
	while (1) {
		# レジスタ指定
		if ($input =~ /^($g_regex_register)/) {
			$input = $` . $';
			my $reg = $1;
			push(@a_term, $reg);
			next;
		}

		# 即値
		#	pea 1234.w
		#	のように、数値の後ろに .b .w .l が付加する可能性がある。
		if ($input =~ /^($g_regex_dec_or_hex)($g_regex_opsize)?/) {
			$input = $` . $';
			my $vale = $1;
			my $field = $2;
			push(@a_term, $vale . $field);
			next;
		}

		# ラベル
		#	.L123.w
		#	のように、ラベルの後ろに .b .w .l が付加する可能性がある。
		#	.L123.O
		#	のように、途中にドットが割り込む場合もあるので注意。
		if ($input =~ /^((?:\.|\w)+)/) {
			$input = $` . $';
			my $label = $1;
			my $field;
			if ($label =~ /^(.*)($g_regex_opsize)$/) {
				$label = $1;
				$field = $2;
			}
			push(@a_term, modify_label($label, $src_location) . $field);
			next;
		}

		# 演算子
		if ($input =~ /^([\+\-\*\/])/) {
			$input = $` . $';
			push(@a_term, $1);
			next;
		}

		# 空になったら終了
		if ($input =~ /^\s*$/) {
			last;
		}

		# ここまでたどり着いたらエラー
		die("$src_location: ERROR: modify_expression failed to parse [$expression].\n");
	}

	# 再結合
	return join('', @a_term);
}


#------------------------------------------------------------------------------
#	引数リストを HAS スタイルに修正する
#
#	[parameters]
#		・$args
#			数式交じりの引数リスト
#
#		・$src_location
#			ソースの位置情報
#
#	[return]
#		HAS スタイルの引数リスト
#------------------------------------------------------------------------------
sub modify_args {
	my (
		$args,
		$src_location
	) = @_;
	my @a_modified_arg;

	# 引数リストをひとつずつ認識して除去していく
	#	評価順序を慎重に設定する必要がある。
	#	例えば、(an) は (an)+ や -(an) にもマッチしてしまうので、
	#	後から評価する必要がある。
	my $input = $args;
	if (DEBUG) {
		print "args : [" . $args . "]\n";
	}
	for (my $i = 0; $i < 2; $i++) {
		# 冒頭のスペースを除去
		$input =~ s/^\s*//g;

		# 第二引数以降は、冒頭のカンマ列を除去
		if ($i != 0) {
			if ($input ne '') {
				if (!($input =~ s/^,//g)) {
					die("$src_location: ERROR: modify_args failed to parse [$args].\n");
				}
			}
		}

		# レジスタ
		if (
			$input =~ /^($g_regex_register)/
		) {
			$input = $` . $';
			my $reg = $1;
			my $modified_arg = $reg;
			if (DEBUG) {
				print "	arg [$modified_arg] as register\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# abs(ix) : -m68030 指定時に出現
		elsif (
			$input =~ /^($g_regex_expression)\(($g_regex_ix)\)($g_regex_bitfield)?/
		) {
			$input = $` . $';
			my $expression	= $1;
			my $reg			= $2;
			my $bitfield	= $3;
			my $modified_arg = modify_expression($expression, $src_location) . '(' . $reg . ')' . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as abs(ix)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# %pc@(d8,ix)
		elsif (
			$input =~ /^%pc@\(($g_regex_expression),($g_regex_ix)\)($g_regex_bitfield)?/
		) {
			$input = $` . $';
			my $expression	= $1;
			my $ix			= $2;
			my $bitfield	= $3;
			my $modified_arg = modify_expression($expression, $src_location) . '(pc,' . $ix . ')' . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as %pc@(d8,ix)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# (an)+
		elsif (
			$input =~ /^\(($g_regex_an)\)\+/
		) {
			$input = $` . $';
			my $reg = $1;
			my $modified_arg = '(' . $reg . ')+';
			if (DEBUG) {
				print "	arg [$modified_arg] as (an)+\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# -(an)
		elsif (
			$input =~ /^\-\(($g_regex_an)\)/
		) {
			$input = $` . $';
			my $reg = $1;
			my $modified_arg = '-(' . $reg . ')';
			if (DEBUG) {
				print "	arg [$modified_arg] as -(an)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# d16(an)
		elsif (
			$input =~ /^($g_regex_expression)\(($g_regex_an)\)($g_regex_bitfield)?/
		) {
			$input = $` . $';
			my $expression	= $1;
			my $reg			= $2;
			my $bitfield	= $3;
			my $modified_arg = modify_expression($expression, $src_location) . '(' . $reg . ')' . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as d16(an)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# (d16,an)
		elsif (
			$input =~ /^\(($g_regex_expression),($g_regex_an)\)($g_regex_bitfield)?/
		) {
			$input = $` . $';
			my $expression	= $1;
			my $reg			= $2;
			my $bitfield	= $3;
			my $modified_arg = modify_expression($expression, $src_location) . '(' . $reg . ')' . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as (d16, an)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# d8(an,ix)
		elsif (
			$input =~ /^($g_regex_expression)\(($g_regex_an),($g_regex_ix)\)($g_regex_bitfield)?/
		) {
			$input = $` . $';
			my $expression	= $1;
			my $reg			= $2;
			my $ix			= $3;
			my $bitfield	= $4;
			my $modified_arg = modify_expression($expression, $src_location) . '(' . $reg . ',' . $ix . ')' . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as d8(an,ix)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# d8(pc,ix)
		elsif (
			$input =~ /^($g_regex_expression)\(%pc,($g_regex_ix)\)($g_regex_bitfield)?/
		) {
			$input = $` . $';
			my $expression	= $1;
			my $ix			= $2;
			my $bitfield	= $3;
			my $modified_arg = modify_expression($expression, $src_location) . '(%pc,' . $ix . ')' . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as d8(pc,ix)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# (an)
		elsif (
			$input =~ /^\(($g_regex_an)\)/
		) {
			$input = $` . $';
			my $reg			= $1;
			my $bitfield	= $2;
			my $modified_arg = '(' . $reg . ')' . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as (an)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# (an,ix)
		elsif (
			$input =~ /^\(($g_regex_an),($g_regex_ix)\)($g_regex_bitfield)?/
		) {
			$input = $` . $';
			my $reg			= $1;
			my $ix			= $2;
			my $bitfield	= $3;
			my $modified_arg = '(' . $reg . ',' . $ix . ')' . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as (an,ix)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# #imm
		elsif (
			$input =~ /^\#($g_regex_expression)/
		) {
			$input = $` . $';
			my $expression = $1;
			my $modified_arg = '#' . modify_expression($expression, $src_location);
			if (DEBUG) {
				print "	arg [$modified_arg] as #imm\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# 数値またはラベル名または式
		elsif (
			$input =~ /^($g_regex_expression)($g_regex_bitfield)?/
		) {
			$input = $` . $';
			my $expression	= $1;
			my $bitfield	= $2;
			my $modified_arg = modify_expression($expression, $src_location) . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as expression\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# 数値またはラベル名または式（括弧つき）
		elsif (
			$input =~ /^\(($g_regex_expression)\)($g_regex_opsize)?($g_regex_bitfield)?/
		) {
			$input = $` . $';
			my $expression	= $1;
			my $opsize		= $2;
			my $bitfield	= $3;
			my $modified_arg = '(' . modify_expression($expression, $src_location) . $opsize . ')' . $bitfield;
			if (DEBUG) {
				print "	arg [$modified_arg] as (expression)\n";
			}
			push(@a_modified_arg, $modified_arg);
		}
		# 検出できないならループを抜ける
		else {
			last;
		}
	}

	# 冒頭のスペースとカンマ列を除去
	$input =~ s/^(\s|,)*//g;

	# すべて分解しきれていないならエラー
	if ($input ne '') {
		die("$src_location: ERROR: modify_args failed to parse [$args].\n");
	}

	# 修正引数リストの結合
	my $modified_arg = join(',', @a_modified_arg);
	return $modified_arg;
}


#------------------------------------------------------------------------------
#	string 文字列を dc.b ダンプに変換する
#
#	[parameters]
#		・$string
#			文字列
#
#	[return]
#		変換結果（末端に 0x00 が付加される）
#------------------------------------------------------------------------------
sub convert_string_to_dump {
	my ($string) = @_;
	my $dump = convert_ascii_to_dump($string) . "\n";
	$dump .= '	.dc.b $00';

	return $dump;
}


#------------------------------------------------------------------------------
#	ascii 文字列を dc.b ダンプに変換する
#
#	[parameters]
#		・$string
#			文字列
#
#	[return]
#		変換結果
#------------------------------------------------------------------------------
sub convert_ascii_to_dump {
	my ($string) = @_;
	my $dump;

	my @decoded = decode_escape_sequence($string);
	my $n = $#decoded + 1;
	my $n_per_line = 8;
	for (my $i = 0; $i < $n; $i += $n_per_line) {
		my $begin = $i;
		my $end   = ($i + $n_per_line < $n)? $i + $n_per_line: $n;
		if ($i != 0) {
			$dump .= "\n";
		}
		$dump .= '	.dc.b ';
		for (my $j = $begin; $j < $end; $j++) {
			if ($j != $begin) { $dump .= ','; }
			$dump .= $decoded[$j];
		}
	}

	return $dump;
}


#------------------------------------------------------------------------------
#	エスケープシーケンスされた文字列のデコード
#
#	[parameters]
#		・$string
#			文字列
#
#	[return]
#		変換結果 ($%02x 形式文字列) の配列
#------------------------------------------------------------------------------
sub decode_escape_sequence {
	my ($string) = @_;

	# 1 文字単位に分解
	my @chars = split('', $string);
	my $n = $#chars + 1;

	# デコード
	my @decoded;
	for (my $i = 0; $i < $n; $i++) {
		if ($chars[$i] eq '\\') {
			# 一般的なエスケープシーケンス
			if    ($chars[$i + 1] eq 'a') { push(@decoded, '$07'); $i += 1; }
			elsif ($chars[$i + 1] eq 'b') { push(@decoded, '$08'); $i += 1; }
			elsif ($chars[$i + 1] eq 't') { push(@decoded, '$09'); $i += 1; }
			elsif ($chars[$i + 1] eq 'n') { push(@decoded, '$0a'); $i += 1; }
			elsif ($chars[$i + 1] eq 'v') { push(@decoded, '$0b'); $i += 1; }
			elsif ($chars[$i + 1] eq 'f') { push(@decoded, '$0c'); $i += 1; }
			elsif ($chars[$i + 1] eq 'r') { push(@decoded, '$0d'); $i += 1; }
			elsif ($chars[$i + 1] eq '\\'){ push(@decoded, '$5c'); $i += 1; }
			# 3桁8進数エンコード
			elsif ('0' <= $chars[$i + 1] && $chars[$i + 1] <= '9') {
				push(@decoded, '$' . sprintf("%02x", oct($chars[$i + 1] . $chars[$i + 2] . $chars[$i + 3])));
				$i += 3;
			}
		} else {
			push(@decoded, '$' . sprintf("%02x", ord($chars[$i])));
		}
	}

	return @decoded;
}


#------------------------------------------------------------------------------
#	桁数の計算
#
#	[parameters]
#		・$string
#			文字列
#
#	[return]
#		桁数
#------------------------------------------------------------------------------
sub calc_columns {
	my ($string) = @_;

	my $columns = 0;

	my @chars = split('', $string);
	foreach my $char (@chars) {
		if    ($char eq '	') {
			$columns = ($columns & ~7) + 8;
		}
		elsif ($char eq "\n") {
			$columns = 0;
		} else {
			$columns++;
		}
	}

	return $columns;
}


