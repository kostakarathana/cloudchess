#import "ChessBridge.h"
#include <iostream>
int main(int argc,char **argv){@autoreleasepool {
 std::string line;while(std::getline(std::cin,line)){
  NSData *data=[[NSString stringWithUTF8String:line.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *request=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSDictionary *result=CCPuzzle(request);
  NSData *output=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
  std::cout<<std::string((const char*)output.bytes,output.length)<<std::endl;
 }
}}
