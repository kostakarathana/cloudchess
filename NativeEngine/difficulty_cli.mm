#import <Foundation/Foundation.h>
#include "PuzzleDifficulty.hpp"
#if __has_include("PuzzleDifficultyModel.hpp")
#include "PuzzleDifficultyModel.hpp"
#endif
#include <iostream>
int main(){std::string line;while(std::getline(std::cin,line)){@autoreleasepool{try{
 NSData *data=[[NSString stringWithUTF8String:line.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
 NSDictionary *r=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
 #if __has_include("PuzzleDifficultyModel.hpp")
 if(r[@"features"]){vector<double>x;for(NSNumber *n in r[@"features"])x.push_back(n.doubleValue);if(x.size()!=Challenge::names().size())throw runtime_error("Invalid feature count");std::cout.precision(17);std::cout<<"{\"prediction\":"<<ChallengeModel::predict(x)<<"}"<<std::endl;continue;}
 #endif
 Board b=parse([r[@"fen"] UTF8String],[r[@"columns"] intValue],[r[@"rows"] intValue]);
 NSMutableDictionary *result=[NSMutableDictionary dictionary];
 if(r[@"botDepth"]){Challenge::Bot bot([r[@"budget"] unsignedLongLongValue]);auto p=bot.run(b,[r[@"botDepth"] intValue]);NSMutableArray *moves=[NSMutableArray array],*scores=[NSMutableArray array];for(auto m:p.moves)[moves addObject:[NSString stringWithUTF8String:m.uci().c_str()]];for(int s:p.scores)[scores addObject:@(s)];result[@"moves"]=moves;result[@"scores"]=scores;result[@"depth"]=@(p.depth);result[@"nodes"]=@(p.nodes);}
 else {vector<string> line;for(NSString *m in r[@"line"])line.push_back(m.UTF8String);auto p=Challenge::measure(b,line);NSMutableArray *values=[NSMutableArray array],*names=[NSMutableArray array],*success=[NSMutableArray array];for(auto v:p.x)[values addObject:@(v)];for(auto &n:Challenge::names())[names addObject:[NSString stringWithUTF8String:n.c_str()]];for(auto v:p.success)[success addObject:@(v)];result[@"features"]=values;result[@"names"]=names;result[@"success"]=success;result[@"nodes"]=@(p.nodes);}
 NSData *out=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];std::cout<<string((const char*)out.bytes,out.length)<<std::endl;
 }catch(const std::exception&e){std::cout<<"{\"error\":\""<<e.what()<<"\"}"<<std::endl;}}}}
