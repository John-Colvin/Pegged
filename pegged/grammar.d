/**
Parser generation module for Pegged.
The Pegged parser itself is in pegged.parser, generated from pegged.examples.peggedgrammar.

The documentation is in the /docs directory.
*/
module pegged.grammar;

import std.conv: to;
import std.stdio;

public import pegged.peg;
public import pegged.introspection;
import pegged.parser;

/**
Option enum to get internal memoization (parse results storing).
*/
enum Memoization { no, yes }

/**
This function takes a (future) module name, a (future) file name and a grammar as a string or a file. 
It writes the corresponding parser inside a module with the given name.
*/
void asModule(Memoization withMemo = Memoization.no)(string moduleName, string grammarString)
{
    asModule!(withMemo)(moduleName, moduleName, grammarString);
}

/// ditto
void asModule(Memoization withMemo = Memoization.no)(string moduleName, string fileName, string grammarString)
{
    import std.stdio;
    auto f = File(fileName ~ ".d","w");
    
    f.write("/**\nThis module was automatically generated from the following grammar:\n\n");
    f.write(grammarString);
    f.write("\n\n*/\n");
    
    f.write("module " ~ moduleName ~ ";\n\n");
    f.write("public import pegged.peg;\n");
    f.write(grammar!(withMemo)(grammarString));
}

/// ditto
void asModule(Memoization withMemo = Memoization.no)(string moduleName, File file)
{
    string grammarDefinition;
    foreach(line; file.byLine)
    { 
        grammarDefinition ~= line ~ '\n';
    }
    asModule!(withMemo)(moduleName, grammarDefinition);
}

/**
Generate a parser from a PEG definition.
The parser is a string containing D code, to be mixed in or written in a file.

----
enum string def = "
Gram:
    A <- 'a' B*
    B <- 'b' / 'c'
";

mixin(grammar(def));

ParseTree p = Gram("abcbccbcd");
----
*/
string grammar(Memoization withMemo = Memoization.no)(string definition)
{
    ParseTree defAsParseTree = Pegged(definition);
    
    if (!defAsParseTree.successful)
        return "static assert(false, `" ~ defAsParseTree.toString() ~ "`);";
    

    string generateCode(ParseTree p)
    {
        string result;
        
        switch (p.name)
        {
            case "Pegged":
                result = generateCode(p.children[0]);
                break;
            case "Pegged.Grammar":
                string grammarName = generateCode(p.children[0]);
                string shortGrammarName = p.children[0].matches[0];
                //string invokedGrammarName = generateCode(transformName(p.children[0]));
                string firstRuleName = generateCode(p.children[1].children[0]);
                
                result =  "struct Generic" ~ shortGrammarName ~ "(TParseTree)\n"
                        ~ "{\n"
                        ~ "    struct " ~ grammarName ~ "\n    {\n"
                        ~ "    enum name = \"" ~ shortGrammarName ~ "\";\n";
                        
                static if (withMemo == Memoization.yes)
                {
                    result ~= "    import std.typecons:Tuple, tuple;\n";
                    result ~= "    static TParseTree[Tuple!(string, size_t)] memo;\n";
                }
                
                result ~= "    static bool isRule(string s)\n"
                        ~ "    {\n"
                        ~ "        switch(s)\n"
                        ~ "        {\n";
                
                ParseTree[] definitions = p.children[1 .. $];
                bool[string] ruleNames; // to avoid duplicates, when using parameterized rules
                string parameterizedRulesSpecialCode; // because param rules need to be put in the 'default' part of the switch
                bool userDefinedSpacing = false;
                
                string paramRuleHandler(string target)
                {
                    return "if (s.length >= "~to!string(shortGrammarName.length + target.length + 3)
                          ~" && s[0.."~to!string(shortGrammarName.length + target.length + 3)~"] == \""~shortGrammarName ~ "." ~ target~"!(\") return true;";
                }
                
                foreach(i,def; definitions)
                {
                    if (def.matches[0] !in ruleNames)
                    {
                        ruleNames[def.matches[0]] = true;
                        
                        if (def.children[0].children.length > 1)
                            parameterizedRulesSpecialCode ~= "                " ~ paramRuleHandler(def.matches[0])~ "\n";
                        else
                            result ~= "            case \"" ~ shortGrammarName ~ "." ~ def.matches[0] ~ "\":\n";
                    }
                    if (def.matches[0] == "Spacing") // user-defined spacing
                        userDefinedSpacing = true;
                }
                result ~= "                return true;\n"
                        ~ "            default:\n"
                        ~ parameterizedRulesSpecialCode
                        ~ "                return false;\n        }\n    }\n";
                
                result ~= "    mixin decimateTree;\n";
                
				// Introspection information
				/+ Disabling it for now (2012/09/16), splicing definition into code causes problems.
                result ~= "    import pegged.introspection;\n"
				        ~ "    static RuleInfo[string] info;\n"
						~ "    static string[] ruleNames;\n" 
						~ "    static this()\n"
						~ "    {\n"
						~ "         info = ruleInfo(q{" ~ definition ~"});\n"
						~ "         ruleNames = info.keys;\n"
						~ "    }\n";
                +/
                // If the grammar provides a Spacing rule, then this will be used.
                // else, the predefined 'spacing' rule is used.
                result ~= userDefinedSpacing ? "" : "    alias spacing Spacing;\n\n";
                    
                // Creating the inner functions, each corresponding to a grammar rule
                foreach(def; definitions)
                    result ~= generateCode(def);
                
                // if the first rule is parameterized (a template), it's impossible to get an opCall
                // because we don't know with which template arguments it should be called.
                // So no opCall is generated in this case.
                if (p.children[1].children[0].children.length == 1) 
                {
                    // General calling interface
                    result ~= "    static TParseTree opCall(TParseTree p)\n"
                           ~  "    {\n"
                           ~  "        TParseTree result = decimateTree(" ~ firstRuleName ~ "(p));\n"
                           ~  "        result.children = [result];\n"
                           ~  "        result.name = \"" ~ shortGrammarName ~ "\";\n"
                           ~  "        return result;\n"
                           ~  "    }\n\n"
                           ~  "    static TParseTree opCall(string input)\n"
                           ~  "    {\n";
                    static if (withMemo == Memoization.yes)
                        result ~= "        memo = null;\n";
                        
                    result ~= "        return " ~ shortGrammarName ~ "(TParseTree(``, false, [], input, 0, 0));\n"
                           ~  "    }\n";
                           
                    result ~= "    static string opCall(GetName g)\n"
                            ~ "    {\n"
                            ~ "        return \"" ~ shortGrammarName ~ "\";\n"
                            ~ "    }\n\n";
                }
                result ~= "    }\n" // end of grammar struct definition
                        ~ "}\n\n" // end of template definition
                        ~ "alias Generic" ~ shortGrammarName ~ "!(ParseTree)." ~ shortGrammarName ~ " " ~ shortGrammarName ~ ";\n\n";
                break;
            case "Pegged.Definition":
                // children[0]: name
                // children[1]: arrow (arrow type as first child)
                // children[2]: description
                
                string code = "pegged.peg.named!(";
                    
                switch(p.children[1].children[0].name)
                {
                    case "Pegged.LEFTARROW":
                        code ~= generateCode(p.children[2]);
                        break;
                    case "Pegged.FUSEARROW":
                        code ~= "pegged.peg.fuse!(" ~ generateCode(p.children[2]) ~ ")";
                        break;
                    case "Pegged.DISCARDARROW":
                        code ~= "pegged.peg.discard!(" ~ generateCode(p.children[2]) ~ ")";
                        break;
                    case "Pegged.KEEPARROW":
                        code ~= "pegged.peg.keep!("~ generateCode(p.children[2]) ~ ")";
                        break;
                    case "Pegged.SPACEARROW":
                        string temp = generateCode(p.children[2]);
                        size_t i = 0;
                        while(i < temp.length-4) // a while loop to make it work at compile-time.
                        {
                            if (temp[i..i+5] == "and!(")
                            {
                                code ~= "spaceAnd!(Spacing, ";
                                i = i + 5;
                            }
                            else
                            {
                                code ~= temp[i];
                                i = i + 1; // ++i doesn't work at CT?
                            }
                        }
                        code ~= temp[$-4..$];
                        break;
                    default:
                        break;
                }
                
                bool parameterizedRule = p.children[0].children.length > 1;
                string completeName = generateCode(p.children[0]);
                string shortName = p.matches[0];
                string innerName;
                
                if (parameterizedRule)
                {
                    result =  "    template " ~ completeName ~ "\n"
                            ~ "    {\n";
                    innerName ~= "`" ~ shortName ~ "!(` ~ ";
                    foreach(i,param; p.children[0].children[1].children)
                        innerName ~= "getName!("~ param.children[0].matches[0] ~ (i<p.children[0].children[1].children.length-1 ? ")() ~ `, ` ~ " : ")");
                    innerName ~= " ~ `)`";
                }
                else
                {
                    innerName ~= "`" ~ completeName ~ "`";
                }
                
                code ~= ", name ~ `.`~ " ~ innerName ~ ")";

                result ~=  "    static TParseTree " ~ shortName ~ "(TParseTree p)\n    {\n";
                        //~  "        " ~ innerName;
                 
                static if (withMemo == Memoization.yes)
                    result ~= "        if(auto m = tuple("~innerName~",p.end) in memo)\n"
                            ~ "            return *m;\n"
                            ~ "        else\n"
                            ~ "        {\n"
                            ~ "            TParseTree result = ";
                else
                    result ~= "        return ";
                
                result ~= code ~ "(p);\n";
                
                static if (withMemo == Memoization.yes)
                    result ~= "            memo[tuple("~innerName~",p.end)] = result;\n"
                           ~  "            return result;\n"
                           ~  "        }\n";
                
                result ~= "    }\n\n";
                result ~= "    static TParseTree " ~ shortName ~ "(string s)\n    {\n";
                                
                static if (withMemo == Memoization.yes)
                    result ~=  "        memo = null;\n";
                
                result ~= "        return " ~ code ~ "(TParseTree(\"\", false,[], s));\n    }\n\n";
                
                result ~= "    static string " ~ shortName ~ "(GetName g)\n    {\n"
                        ~ "        return name ~ `.`~ " ~ innerName ~ ";\n    }\n\n";
                
                if (parameterizedRule)
                    result ~= "     }\n";
                
                break;
            case "Pegged.GrammarName":
                result = generateCode(p.children[0]);
                if (p.children.length == 2)
                    result ~= generateCode(p.children[1]);
                break;
            case "Pegged.LhsName":
                result = generateCode(p.children[0]);
                if (p.children.length == 2)
                    result ~= generateCode(p.children[1]);
                break;
            case "Pegged.ParamList":
                result = "(";
                foreach(i,child; p.children)
                    result ~= generateCode(child) ~ ", ";
                result = result[0..$-2] ~ ")";
                break;
            case "Pegged.Param":
                result = "alias " ~ generateCode(p.children[0]);
                break;
            case "Pegged.SingleParam":
                result = p.matches[0];
                break;
            case "Pegged.DefaultParam":
                result = p.matches[0] ~ " = " ~ generateCode(p.children[1]);
                break;
            case "Pegged.Expression":
                if (p.children.length > 1) // OR expression
                {
                    // Keyword list detection: "abstract"/"alias"/...
                    bool isLiteral(ParseTree p)
                    {
                        return ( p.name == "Pegged.Sequence"
                              && p.children.length == 1
                              && p.children[0].children.length == 1
                              && p.children[0].children[0].children.length == 1
                              && p.children[0].children[0].children[0].children.length == 1
                              && p.children[0].children[0].children[0].children[0].name == "Pegged.Literal");
                    }
                    bool keywordList = true;
                    foreach(child;p.children)
                        if (!isLiteral(child))
                        {
                            keywordList = false;
                            break;
                        }
                    
                    if (keywordList)
                    {
                        result = "pegged.peg.keywords!(";
                        foreach(seq; p.children)
                            result ~= "\"" ~ seq.matches[0] ~ "\", ";
                        result = result[0..$-2] ~ ")";
                    }
                    else
                    {
                        result = "pegged.peg.or!(";
                        foreach(seq; p.children)
                            result ~= generateCode(seq) ~ ", ";
                        result = result[0..$-2] ~ ")";
                    }
                }
                else // One child -> just a sequence, no need for a or!( , )
                {
                    result = generateCode(p.children[0]);
                }
                break;
            case "Pegged.Sequence":
                if (p.children.length > 1) // real sequence
                {
                    result = "pegged.peg.and!(";
                    foreach(seq; p.children)
					{
                        string elementCode = generateCode(seq);
						if (elementCode.length > 6 && elementCode[0..5] == "pegged.peg.and!(") // flattening inner sequences
							elementCode = elementCode[5..$-1]; // cutting 'and!(' and ')'
						result ~= elementCode ~ ", ";
					}
                    result = result[0..$-2] ~ ")";
                }
                else // One child -> just a Suffix, no need for a and!( , )
                {
                    result = generateCode(p.children[0]);
                }
                break;
            case "Pegged.Prefix":
                result = generateCode(p.children[$-1]);
                foreach(child; p.children[0..$-1])
                    result = generateCode(child) ~ result ~ ")";
                break;
            case "Pegged.Suffix":
                result = generateCode(p.children[0]);
                foreach(child; p.children[1..$])
                {
                    switch (child.name)
                    {
                        case "Pegged.OPTION":
                            result = "pegged.peg.option!(" ~ result ~ ")";
                            break;
                        case "Pegged.ZEROORMORE":
                            result = "pegged.peg.zeroOrMore!(" ~ result ~ ")";
                            break;
                        case "Pegged.ONEORMORE":
                            result = "pegged.peg.oneOrMore!(" ~ result ~ ")";
                            break;
                        case "Pegged.Action":
                            foreach(action; child.matches)
                                result = "pegged.peg.action!(" ~ result ~ ", " ~ action ~ ")";
                            break;
                        default:
                            break;
                    }
                }
                break;
            case "Pegged.Primary":
                result = generateCode(p.children[0]);
                break;
            case "Pegged.RhsName":
                result = "";
                foreach(i,child; p.children)
                    result ~= generateCode(child);
                break;
            case "Pegged.ArgList":
                result = "!(";
                foreach(child; p.children)
                    result ~= generateCode(child) ~ ", "; // Allow  A <- List('A'*,',') 
                result = result[0..$-2] ~ ")";
                break;
            case "Pegged.Identifier":
                result = p.matches[0];
                break;
            case "Pegged.NAMESEP":
                result = ".";
                break;
            case "Pegged.Literal":
                result = "pegged.peg.literal!(\"" ~ p.matches[0] ~ "\")";
                break;
            case "Pegged.CharClass":
                if (p.children.length > 1)
                {
                    result = "pegged.peg.or!(";
                    foreach(seq; p.children)
                        result ~= generateCode(seq) ~ ", ";
                    result = result[0..$-2] ~ ")";
                }
                else // One child -> just a sequence, no need for a or!( , )
                {
                    result = generateCode(p.children[0]);
                }
                break;
            case "Pegged.CharRange":
                if (p.children.length > 1) // a-b range
                {
                    result = "pegged.peg.charRange!('" ~ generateCode(p.children[0]) ~ "', '" ~ generateCode(p.children[1]) ~ "')";
                }
                else // lone char
                {
                    result = "pegged.peg.literal!(\"" ~ generateCode(p.children[0]) ~ "\")";
                }
                break;
            case "Pegged.Char":
                string ch = p.matches[0];
                if(ch == "\\[" || ch == "\\]" || ch == "\\-")
                    result = ch[1..$];
                else
                    result = ch;
                break;
            case "Pegged.POS":
                result = "pegged.peg.posLookahead!(";
                break;
            case "Pegged.NEG":
                result = "pegged.peg.negLookahead!(";
                break;
            case "Pegged.FUSE":
                result = "pegged.peg.fuse!(";
                break;
            case "Pegged.DISCARD":
                result = "pegged.peg.discard!(";
                break;
            //case "Pegged.CUT":
            //    result = "discardChildren!(";
            //    break;
            case "Pegged.KEEP":
                result = "pegged.peg.keep!(";
                break;
            case "Pegged.DROP":
                result = "pegged.peg.drop!(";
                break;
            case "Pegged.OPTION":
                result = "pegged.peg.option!(";
                break;
            case "Pegged.ZEROORMORE":
                result = "pegged.peg.zeroOrMore!(";
                break;
            case "Pegged.ONEORMORE":
                result = "pegged.peg.oneOrMore!(";
                break;
            case "Pegged.Action":
                result = generateCode(p.children[0]);
                foreach(action; p.matches[1..$])
                    result = "pegged.peg.action!(" ~ result ~ ", " ~ action ~ ")";
                break;
            case "Pegged.ANY":
                result = "pegged.peg.any";
                break;
            default:
                result = "Bad tree: " ~ p.toString();
                break;
        }
        return result;
    }
	

	
    return generateCode(defAsParseTree);
}

/**
Mixin to get what a failed rule expected as input.
Not used by Pegged yet.
*/
mixin template expected()
{
    string expected(ParseTree p)
    {
        
        switch(p.name)
        {
            case "Pegged.Expression":
                string expectation;
                foreach(i, child; p.children)
                    expectation ~= "(" ~ expected(child) ~ ")" ~ (i < p.children.length -1 ? " or " : "");
                return expectation;
            case "Pegged.Sequence":
                string expectation;
                foreach(i, expr; p.children)
                    expectation ~= "(" ~ expected(expr) ~ ")" ~ (i < p.children.length -1 ? " followed by " : "");
                return expectation;
            case "Pegged.Prefix":
                return expected(p.children[$-1]);
            case "Pegged.Suffix":
                string expectation;
                string end;
                foreach(prefix; p.children[1..$])
                    switch(prefix.name)
                    {
                        case "Pegged.ZEROORMORE":
                            expectation ~= "zero or more times (";
                            end ~= ")";
                            break;
                        case "Pegged.ONEORMORE":
                            expectation ~= "one or more times (";
                            end ~= ")";
                            break;
                        case "Pegged.OPTION":
                            expectation ~= "optionally (";
                            end ~= ")";
                            break;
                        case "Pegged.Action":
                            break;
                        default:
                            break;
                    }
                return expectation ~ expected(p.children[0]) ~ end;
            case "Pegged.Primary":
                return expected(p.children[0]);
            //case "Pegged.RhsName":
            //    return "RhsName, not implemented.";
            case "Pegged.Literal":
                return "the literal `" ~ p.matches[0] ~ "`";
            case "Pegged.CharClass":
                string expectation;
                foreach(i, child; p.children)
                    expectation ~= expected(child) ~ (i < p.children.length -1 ? " or " : "");
                return expectation;            
            case "Pegged.CharRange":
                if (p.children.length == 1)
                    return expected(p.children[0]);
                else
                    return "any character between '" ~ p.matches[0] ~ "' and '" ~ p.matches[2] ~ "'";
            case "Pegged.Char":
                return "the character '" ~ p.matches[0] ~ "'";
            case "Pegged.ANY":
                return "any character";
            default:
                return "unknow rule (" ~ p.matches[0] ~ ")";
        }
    }
}