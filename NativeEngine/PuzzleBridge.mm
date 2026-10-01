#import "ChessBridge.h"
#include "PuzzleProof.hpp"
#include "PuzzleDifficulty.hpp"
#include "PuzzleDifficultyModel.hpp"
#include <set>

static NSString *ps(const string &s){return [NSString stringWithUTF8String:s.c_str()];}
static NSArray *pm(const vector<Move>&moves){NSMutableArray *a=[NSMutableArray array];for(auto m:moves)[a addObject:ps(m.uci())];return a;}
static uint64_t attacksFrom(const Board&b,int square){
    uint64_t result=0;int f=square%8,r=square/8,t=abs(b.p[square]),side=b.p[square]>0?1:-1;
    auto add=[&](int x,int y){if(b.inside(x,y))result|=uint64_t(1)<<(y*8+x);};
    if(t==1){add(f-1,r+side);add(f+1,r+side);}
    else if(t==2){for(auto dx:{-2,-1,1,2})for(auto dy:{-2,-1,1,2})if(abs(dx)+abs(dy)==3)add(f+dx,r+dy);}
    else for(int dx=-1;dx<=1;dx++)for(int dy=-1;dy<=1;dy++)if(dx||dy){
        if(t==3&&!(dx&&dy))continue;if(t==4&&dx&&dy)continue;
        int x=f+dx,y=r+dy;while(b.inside(x,y)){add(x,y);if(b.p[y*8+x]||t==6)break;x+=dx;y+=dy;}
    }
    return result;
}
static NSArray *puzzleTags(Board b,NSArray *line,int mate){
    const char *names[]={"","pawn","knight","bishop","rook","queen","king"};
    set<string> tags{mate?"plan:mate"+(mate>=4?string("4plus"):to_string(mate)):"plan:improvement"};int i=0,count=0,nonpawn=0;
    for(int sq=0;sq<64;sq++)if(b.p[sq]){
        count++;int t=abs(b.p[sq]);nonpawn+=(int[]){0,0,3,3,5,9,0}[t];
        if(t!=6){int side=b.p[sq]>0?1:-1,k=b.king(side),dx=sq%8-k%8,dy=sq/8-k/8;
            if(dx==0||dy==0||abs(dx)==abs(dy)){
                dx=(dx>0)-(dx<0);dy=(dy>0)-(dy<0);int x=k%8+dx,y=k/8+dy;bool found=false;
                while(b.inside(x,y)){int at=y*8+x,v=b.p[at];if(v){if(!found&&at==sq)found=true;else{int pt=abs(v);if(found&&v*side<0&&(pt==5||(dx&&dy?pt==3:pt==4)))tags.insert("absolutePin");break;}}x+=dx;y+=dy;}
            }
        }
    }
    tags.insert(nonpawn<=20||count<=10?"phase:endgame":"phase:middlegame");
    if(b.check(b.turn))tags.insert("inCheck");
    if(mate)tags.insert("conversion");
    for(NSString *token in line){auto legal=b.legal();auto it=find_if(legal.begin(),legal.end(),[&](Move m){return m.uci()==token.UTF8String;});if(it==legal.end())break;
        Move m=*it;int type=abs(b.p[m.a]),side=b.turn;auto old=attacksFrom(b,m.a);bool ep=type==1&&m.b==b.ep;bool capture=b.p[m.b]||ep;
        b=b.push(m);
        if(i%2==0){
            if(i==0)tags.insert(string("first:")+names[type]);
            if(capture)tags.insert("capture");
            if(ep)tags.insert("enPassant");
            if(b.check(b.turn))tags.insert("check");else if(!capture)tags.insert("quietMove");
            if(m.prom){tags.insert("promotion");if(m.prom!=5)tags.insert("underPromotion");}
            int checks=0;for(int sq=0;sq<64;sq++)if(b.p[sq]*side>0&&(attacksFrom(b,sq)&(uint64_t(1)<<b.king(-side)))){checks++;if(sq!=m.b)tags.insert("discoveredCheck");}
            if(checks>1)tags.insert("doubleCheck");
            auto targets=attacksFrom(b,m.b);for(int sq=0;sq<64;sq++)if(b.p[sq]*side>=0||abs(b.p[sq])==1)targets&=~(uint64_t(1)<<sq);
            if(__builtin_popcountll(targets)>=2&&(targets&~old)){
                tags.insert("fork");tags.insert(string("fork:")+names[abs(b.p[m.b])]);
                bool king=false,queen=false;for(int sq=0;sq<64;sq++)if(targets&(uint64_t(1)<<sq)){king|=abs(b.p[sq])==6;queen|=abs(b.p[sq])==5;}if(king&&queen)tags.insert("royalFork");
            }
        }i++;
    }
    NSMutableArray *result=[NSMutableArray array];for(auto &t:tags)[result addObject:ps(t)];return result;
}
// This engine has no heuristic acceptance: an exhausted proof budget is an error,
// never a wrong answer and never a certified puzzle. Initial castling is absent
// by construction; orthodox pawn doubles/EP remain enabled only on 8x8.
NSDictionary *CCPuzzle(NSDictionary *r){
 struct ClearCancellation {~ClearCancellation(){puzzleCancelled=nullptr;}} clear;
 const bool background=r[@"_backgroundEpoch"]!=nil;
 const uint64_t epoch=[r[@"_backgroundEpoch"] unsignedLongLongValue];
 puzzleCancelled=background ? std::function<bool()>([epoch]{return epoch!=CCBackgroundEpoch();}):nullptr;
 try {
    checkPuzzleCancellation();
    if(![r[@"initial"] isKindOfClass:NSString.class])throw runtime_error("Missing initial position");
    Board b=parse([r[@"initial"] UTF8String],[r[@"columns"] intValue],[r[@"rows"] intValue]);
    Board initial=b;
    int attacker=b.turn,mate=[r[@"mate"] intValue],gain=[r[@"gain"] intValue];
    int horizon=mate ? 2*mate-1:[r[@"plies"] intValue],target=b.material(attacker)+gain;
    if(mate<0||mate>5||horizon<1||horizon>10||(!mate&&(gain<1||gain>20)))throw runtime_error("Invalid objective");
    NSArray *history=r[@"moves"]?:@[];
    if(history.count>NSUInteger(horizon))throw runtime_error("History past objective");
    NSMutableArray *white=[NSMutableArray array],*black=[NSMutableArray array];
    for(NSString *token in history){
        auto legal=b.legal();auto it=find_if(legal.begin(),legal.end(),[&](Move m){return m.uci()==token.UTF8String;});
        if(it==legal.end())throw runtime_error("Illegal puzzle history");
        int captured=abs(b.p[it->b]);if(!captured&&abs(b.p[it->a])==1&&it->b==b.ep)captured=1;
        if(captured)[(b.turn==1?white:black) addObject:[NSString stringWithFormat:@"%c"," PNBRQK"[captured]]];
        b=b.push(*it);
    }
    auto legal=b.legal();int depth=horizon-int(history.count);
    bool mated=legal.empty()&&b.check(b.turn)&&b.turn!=attacker;
    bool solved=mated||(!mate&&depth==0&&!legal.empty()&&!b.dead()&&b.material(attacker)>=target);
    NSMutableDictionary *out=[@{@"fen":ps(fen(b)),@"moves":history,@"san":history,@"legal":pm(legal),@"turn":b.turn==1?@"white":@"black",@"check":@(b.check(b.turn)),@"result":b.dead()?@"Draw":legal.empty()?(b.check(b.turn)?@"Checkmate":@"Draw"):NSNull.null,@"capturedWhite":white,@"capturedBlack":black,@"lastMove":history.lastObject?:NSNull.null,@"columns":@(b.n),@"rows":@(b.h),@"solved":@(solved),@"remaining":@(depth)} mutableCopy];
    NSString *op=r[@"operation"]?:@"position";
    if(solved)out[@"tags"]=puzzleTags(initial,history,mate);
    if([op isEqual:@"position"]||solved)return out;
    auto budget=r[@"budget"]?std::min(1000000ULL,[r[@"budget"] unsignedLongLongValue]):400000ULL;
    Search search(attacker,budget,mate?0:1,target);
    if([op isEqual:@"judge"]){
        if(b.turn!=attacker||depth<=0)throw runtime_error("Not a solver decision");
        NSString *candidate=r[@"candidate"];
        auto move=find_if(legal.begin(),legal.end(),[&](Move m){return candidate && m.uci()==candidate.UTF8String;});
        if(move==legal.end())throw runtime_error("Illegal candidate");
        // Prove the submitted continuation against EVERY legal defense. A PV
        // or a cached answer list is never grounds for rejecting an alternative.
        out[@"accepted"]=@(search.force(b.push(*move),depth-1));
        out[@"nodes"]=@(search.nodes);return out;
    }
    if(depth<=0||!search.force(b,depth))throw runtime_error("Objective not forced");
    if([op isEqual:@"certify"]){
        if(history.count)throw runtime_error("Certification requires root");
        auto winners=search.winners(b,depth);
        bool exact=!mate||mate==1||!search.force(b,depth-2);
        if(winners.size()!=1||!exact)throw runtime_error("Ambiguous or shorter objective");
        out[@"winning"]=pm(winners);
    } else if(b.turn==attacker)out[@"winning"]=pm(search.winners(b,depth));
    vector<Move> line=mate?search.line(b,depth):search.material_line(b,depth);
    if(line.empty())throw runtime_error("Missing proof continuation");
    if([op isEqual:@"certify"]&&!mate){
        Board end=b;for(auto m:line)end=end.push(m);
        if(end.legal().empty())throw runtime_error("Use a mating objective");
    }
    if([r[@"measureDifficulty"] boolValue]) {
        if(![op isEqual:@"certify"]||history.count)throw runtime_error("Difficulty requires root certificate");
        vector<string> moves;for(auto m:line)moves.push_back(m.uci());
        auto measured=Challenge::measure(initial,moves);checkPuzzleCancellation();
        double rating=round(max(400.0,min(3000.0,ChallengeModel::predict(measured.x))));
        double uncertainty=round(ChallengeModel::residual80*(b.n==8&&b.h==8?1.0:1.35));
        double complexity=round(min(100.0,10+10*log2(1+measured.x[18])+8*measured.x[15]+4*measured.x[25]));
        NSMutableArray *probabilities=[NSMutableArray array];for(auto p:measured.success)[probabilities addObject:@(p)];
        out[@"difficulty"]=@{@"version":ps(Challenge::version),@"rating":@(rating),@"uncertainty":@(uncertainty),@"complexity":@(complexity),@"seconds":@(round(10+10*measured.x[15]+0.5*complexity)),@"botSuccess":probabilities,@"probeNodes":@(measured.nodes)};
    }
    out[@"line"]=pm(line);out[@"nodes"]=@(search.nodes);
    NSMutableArray *full=[history mutableCopy];[full addObjectsFromArray:pm(line)];out[@"tags"]=puzzleTags(initial,full,mate);return out;
 }catch(Budget&){return @{@"error":@"Proof budget exhausted; position was not graded",@"unknown":@YES};}
 catch(const exception &e){return @{@"error":ps(e.what())};}
}
