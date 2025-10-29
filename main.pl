#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use feature 'say';

use WWW::Telegram::BotAPI;
use URI::Escape;

my $token = $ENV{BOT_TOKEN} || die "BOT_TOKEN environment variable is required!";

my $api = WWW::Telegram::BotAPI->new(
    token => $token,
    async => 0
);

my %cache;

my $bot_username = get_bot_username();

say "Bot started successfully";

my $offset = 0;
while (1) {
    eval {
        my $updates = $api->getUpdates({
            offset => $offset,
            timeout => 30
        });
        
        if ($updates && $updates->{ok}) {
            foreach my $update (@{$updates->{result}}) {
                $offset = $update->{update_id} + 1;
                
                if ($update->{inline_query}) {
                    handle_inline_query($update->{inline_query});
                }
                
                if ($update->{message}) {
                    handle_message($update->{message});
                }
            }
        }
    };
    
    if ($@) {
        warn "Error: $@";
        sleep 5;
    }
    
    sleep 1;
}

sub get_bot_username {
    my $me = $api->getMe;
    return $me->{result}{username};
}

sub handle_inline_query {
    my $inline_query = shift;
    my $query = $inline_query->{query} || '';
    my $query_id = $inline_query->{id};
    
    return unless $query;
    
    say "Inline query: $query";
    
    my @results;
    
    my ($section, $command) = parse_man_query($query);
    my $man_results = search_man_pages($command, $section);
    push @results, @$man_results if $man_results;
    
    @results = @results[0..4] if @results > 5;
    
    if (!@results) {
        push @results, {
            type => 'article',
            id => 'usage_help',
            title => 'Usage Help',
            input_message_content => {
                message_text => get_usage_help(),
                parse_mode => 'HTML'
            },
            description => 'How to use this bot'
        };
    }
    
    eval {
        $api->answerInlineQuery({
            inline_query_id => $query_id,
            results => \@results,
            cache_time => 300
        });
    };
    
    if ($@) {
        warn "Error answering inline query: $@";
    }
}

sub handle_message {
    my $message = shift;
    my $chat_id = $message->{chat}{id};
    my $text = $message->{text} || '';
    
    return unless $text;
    
    if ($text =~ m{^/start|/help}i) {
        $api->sendMessage({
            chat_id => $chat_id,
            text => get_usage_help(),
            disable_web_page_preview => 0,
            parse_mode => 'HTML'
        });
        return;
    }
    
    if ($text =~ m{^/?(man\s+)?(\d\s+)?(\w+)}i) {
        my $section = $2 ? $2 : '';
        my $command = $3;
        $section =~ s/\s+//g if $section;
        
        my $response = generate_help_response($command, $section);
        $api->sendMessage({
            chat_id => $chat_id,
            text => $response,
            parse_mode => 'HTML'
        });
    }
}

sub parse_man_query {
    my $query = shift;
    
    if ($query =~ /^(\d+)\s+(\w+)$/) {
        return ($1, $2);
    }
    elsif ($query =~ /^man\s+(\d+)\s+(\w+)$/i) {
        return ($1, $2);
    }
    elsif ($query =~ /^man\s+(\w+)$/i) {
        return (undef, $1);
    }
    else {
        return (undef, $query);
    }
}

sub search_man_pages {
    my ($command, $section) = @_;
    my @results;
    
    return [] unless $command =~ /^\w+$/;
    
    my ($description, $first_paragraph) = get_command_description_and_paragraph($command, $section);
    
    my $title = $section ? "man $section $command" : "man $command";
    
    my $inline_description = $description || "View man page for $command";
    if ($first_paragraph && length($first_paragraph) > 0) {
        my $truncated_para = substr($first_paragraph, 0, 80);
        $truncated_para .= "..." if length($first_paragraph) > 80;
        $inline_description = $truncated_para;
    } elsif ($description && length($description) > 0) {
        my $truncated_desc = substr($description, 0, 80);
        $truncated_desc .= "..." if length($description) > 80;
        $inline_description = $truncated_desc;
    }
    
    push @results, {
        type => 'article',
        id => 'man_' . ($section ? "${section}_" : '') . $command,
        title => $title,
        input_message_content => {
            message_text => generate_help_response($command, $section),
            parse_mode => 'HTML'
        },
        description => $inline_description
    };
    
    return \@results;
}

sub get_command_description_and_paragraph {
    my ($command, $section) = @_;
    
    my $cache_key = "desc_" . ($section ? "${section}_" : '') . $command;
    if (exists $cache{$cache_key}) {
        return @{$cache{$cache_key}};
    }
    
    my ($description, $first_paragraph) = get_local_man_description_and_paragraph($command, $section);
    if ($description || $first_paragraph) {
        $cache{$cache_key} = [$description, $first_paragraph];
        return ($description, $first_paragraph);
    }
    
    return (undef, undef);
}

sub get_local_man_description_and_paragraph {
    my ($command, $section) = @_;
    
    my $description;
    my $first_paragraph;
    
    eval {
        my $whatis_cmd = $section ? "whatis -s $section $command 2>/dev/null" : "whatis $command 2>/dev/null";
        my $whatis_output = `$whatis_cmd | head -1`;
        chomp $whatis_output;
        
        if ($whatis_output && $whatis_output !~ /^$command: nothing appropriate$/i) {
            if ($whatis_output =~ /$command\s*\((\d+)\)\s+[-–]\s*(.+)$/i) {
                $description = $2;
                $description =~ s/^\s+|\s+$//g;
                say "Found local man description: $description" if $description;
            }
            elsif ($whatis_output =~ /$command\s+[-–]\s*(.+)$/i) {
                $description = $1;
                $description =~ s/^\s+|\s+$//g;
                say "Found local man description (alt): $description" if $description;
            }
        }
    };
    
    eval {
        my $man_cmd = $section ? 
            "man $section $command 2>/dev/null" : 
            "man $command 2>/dev/null";
        
        open my $man_fh, "$man_cmd | col -b 2>/dev/null | head -100 |" or return;
        my @man_lines = <$man_fh>;
        close $man_fh;
        
        my $man_content = join('', @man_lines);
        
        if ($man_content && $man_content !~ /No manual entry|nothing appropriate/i) {
            if ($man_content =~ /NAME\s*\n\s*(\S+.*?)(?:\n\n|\n\s*\n|\n[A-Z][A-Z\s]+\n|\nDESCRIPTION|\nSYNOPSIS|\z)/is) {
                my $name_section = $1;
                
                $name_section =~ s/\s+/ /g;
                $name_section =~ s/^\s+|\s+$//g;
                
                if ($name_section =~ /$command\s*[-–—]\s*(.+)$/i) {
                    $first_paragraph = $1;
                    $first_paragraph =~ s/^\s+|\s+$//g;
                    
                    if (!$description && $first_paragraph) {
                        $description = $first_paragraph;
                        if ($description =~ /^([^.]+\.[^.]*)/) {
                            $description = $1;
                        }
                    }
                    
                    say "Extracted first paragraph: $first_paragraph" if $first_paragraph;
                }
            }
            
            if (!$first_paragraph && $man_content =~ /DESCRIPTION\s*\n(.*?)(?:\n\n|\n\s*\n|\n[A-Z][A-Z\s]+\n|\z)/is) {
                my $desc_section = $1;
                $desc_section =~ s/\s+/ /g;
                $desc_section =~ s/^\s+|\s+$//g;
                
                if ($desc_section =~ /^([^.]{10,200}\.)/) {
                    $first_paragraph = $1;
                } elsif (length($desc_section) > 10) {
                    $first_paragraph = substr($desc_section, 0, 200);
                    $first_paragraph =~ s/\s+\S*$//;
                    $first_paragraph .= "..." if length($desc_section) > 200;
                }
                
                say "Extracted from DESCRIPTION: $first_paragraph" if $first_paragraph;
            }
        }
    };
    
    return ($description, $first_paragraph);
}

sub generate_help_response {
    my ($command, $section) = @_;
    
    my $actual_section = find_actual_section($command, $section);
    
    my $man_url = "https://man7.org/linux/man-pages/man$actual_section/$command.$actual_section.html";
    my $die_net_url = "https://linux.die.net/man/$actual_section/$command";
    my $die_net_search = "https://linux.die.net/search/?q=" . uri_escape("$command $actual_section");
    
    my ($description, $first_paragraph) = get_command_description_and_paragraph($command, $actual_section);
    my $response = "<b>$command" . ($actual_section ? "($actual_section)" : "") . "</b>";
    $response .= "\n\n";
    
    if ($description) {
        $response .= "<i>$description</i>\n\n";
    }
    
    if ($first_paragraph && $first_paragraph ne $description) {
        if (length($first_paragraph) > 500) {
            $first_paragraph = substr($first_paragraph, 0, 497) . "...";
        }
        $response .= "$first_paragraph\n\n";
    }
    
    $response .= "<b>Documentation Links:</b>\n";
    $response .= "• <a href=\"$man_url\">man7.org</a>\n";
    $response .= "• <a href=\"$die_net_url\">linux.die.net</a>\n";
    $response .= "• <a href=\"$die_net_search\">Search linux.die.net</a>";
    
    return $response;
}

sub find_actual_section {
    my ($command, $preferred_section) = @_;
    
    if ($preferred_section) {
        my $exists = system("man -w $preferred_section $command >/dev/null 2>&1") == 0;
        return $preferred_section if $exists;
    }
    
    my $whatis_output = `whatis $command 2>/dev/null | head -1`;
    if ($whatis_output && $whatis_output =~ /$command\s*\((\d+)\)/) {
        return $1;
    }
    
    my @common_sections = qw(1 2 3 4 5 6 7 8);
    foreach my $section (@common_sections) {
        my $exists = system("man -w $section $command >/dev/null 2>&1") == 0;
        return $section if $exists;
    }
    
    return $preferred_section || '1';
}

sub get_usage_help {
    return "<b>Hi there!</b>\n\n" .
           "Search for man pages.\n\n" .
           "<b>Inline Search:</b>\n" .
           "Type \@$bot_username followed by a command name in any chat\n\n" .
           "<b>Supported formats:</b>\n" .
           "ls\n" .
           "1 malloc\n" .
           "man 1 malloc\n" .
           "man 2 open";
}
