#import "ChessBridge.h"
#include <future>
#include <chrono>
#include <thread>
#include <iostream>
using Clock=std::chrono::steady_clock;
int main(int argc,char **argv){@autoreleasepool {
 NSString *network=[NSString stringWithUTF8String:argv[1]];
 CCChess(@{@"action":@"analyse",@"nodes":@1000},network);
 auto search=std::async(std::launch::async,[&]{@autoreleasepool{return CCChess(@{@"action":@"analyse",@"nodes":@8000000},network);}});
 std::this_thread::sleep_for(std::chrono::milliseconds(30));
 double maximum=0;int checks=0;
 for(int i=0;i<1000;i++){@autoreleasepool{
  auto start=Clock::now();NSDictionary *r=CCChess(@{@"action":@"state",@"moves":@[@"e2e4",@"e7e5",@"g1f3"]},network);
  if(r[@"error"]||[r[@"legal"] count]!=29)return 2;
  maximum=std::max(maximum,std::chrono::duration<double>(Clock::now()-start).count());checks++;
 }}
 bool overlapped=search.wait_for(std::chrono::milliseconds(0))!=std::future_status::ready;
 auto result=search.get();if(!overlapped||maximum>0.5||[result[@"limitedStrength"] boolValue])return 3;
 auto bot=CCChess(@{@"action":@"bot",@"elo":@600,@"nodes":@10000},network);
 auto strong=CCChess(@{@"action":@"analyse",@"nodes":@10000},network);
 if(![bot[@"limitedStrength"] boolValue]||[strong[@"limitedStrength"] boolValue])return 4;
 std::cout<<"{\"status\":\"passed\",\"stateChecks\":"<<checks<<",\"searchOverlapped\":true,\"maxStateSeconds\":"<<maximum<<",\"strengthReset\":true}"<<std::endl;
}}
