#import "ChessBridge.h"
#include "Stockfish/engine.h"
#include "Stockfish/attacks.h"
#include "Stockfish/position.h"
#include "Stockfish/movegen.h"
#include "Stockfish/uci.h"
#include <mutex>
#include <atomic>
#include <set>
#include <sstream>
#if defined(CC_DUAL_ENGINE) && !defined(CC_DOTPROD_VARIANT)
#include <sys/sysctl.h>
FOUNDATION_EXPORT NSDictionary *CCDotprodChess(NSDictionary *,NSString *);
FOUNDATION_EXPORT void CCDotprodStop(void);
FOUNDATION_EXPORT uint64_t CCDotprodBackgroundEpoch(void);
FOUNDATION_EXPORT void CCDotprodStopBackground(void);
static bool useDotprod() {
    static const bool enabled=[] {
#if defined(CC_ENGINE_TESTING)
        if(getenv("CC_FORCE_BASELINE_ENGINE"))return false;
#endif
        int supported=0;size_t size=sizeof(supported);
        return sysctlbyname("hw.optional.arm.FEAT_DotProd",&supported,&size,nullptr,0)==0 && supported==1;
    }();
    return enabled;
}
#endif
using namespace Stockfish;
using namespace Stockfish::Attacks;
static constexpr Bitboard DarkSquares=0xAA55AA55AA55AA55ULL;
static std::atomic<Engine*> stopping{nullptr};
static std::mutex serial;
static std::mutex backgroundLock;
static std::atomic<uint64_t> backgroundEpoch{1};
static bool activeBackground=false;
uint64_t CCBackgroundEpoch(void){
#if defined(CC_DUAL_ENGINE) && !defined(CC_DOTPROD_VARIANT)
    if(useDotprod())return CCDotprodBackgroundEpoch();
#endif
    return backgroundEpoch.load();
}
void CCStopBackground(void){
#if defined(CC_DUAL_ENGINE) && !defined(CC_DOTPROD_VARIANT)
    if(useDotprod()){CCDotprodStopBackground();return;}
#endif
    std::lock_guard<std::mutex> guard(backgroundLock);
    backgroundEpoch.fetch_add(1);
    if(activeBackground) {if(auto e=stopping.load())e->stop();}
}
static std::once_flag initialized;
static std::unique_ptr<Engine> engine;

static NSString *str(const std::string &s) {return [NSString stringWithUTF8String:s.c_str()];}
static std::string cpp(NSString *s) {return s ? std::string(s.UTF8String):std::string();}
static const char *names[]={"","pawn","knight","bishop","rook","queen","king"};
static const char *letters=" PNBRQK";
static NSString *normalized(NSString *s) {
    s=[s stringByReplacingOccurrencesOfString:@"0" withString:@"O"];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"+#!?\r\n "]];
}
static std::string san(Position &p,Move m) {
    if(m.type_of()==CASTLING) return m.to_sq()>m.from_sq()?"O-O":"O-O-O";
    auto pt=type_of(p.moved_piece(m));std::string s;
    if(pt!=PAWN) {
        s+=letters[pt];bool other=false,sameFile=false,sameRank=false;
        for(auto n:MoveList<LEGAL>(p)) if(n!=m && n.to_sq()==m.to_sq() && type_of(p.moved_piece(n))==pt) {
            other=true;sameFile|=file_of(n.from_sq())==file_of(m.from_sq());sameRank|=rank_of(n.from_sq())==rank_of(m.from_sq());
        }
        if(other) {if(!sameFile) s+=char('a'+file_of(m.from_sq()));else if(!sameRank) s+=char('1'+rank_of(m.from_sq()));else s+=UCIEngine::square(m.from_sq());}
    } else if(p.capture(m)) s+=char('a'+file_of(m.from_sq()));
    if(p.capture(m))s+='x';s+=UCIEngine::square(m.to_sq());
    if(m.type_of()==PROMOTION){s+='=';s+=letters[m.promotion_type()];}
    return s;
}
static Bitboard targets(const Position &p,Square sq,Color own) {
    auto pt=type_of(p.piece_on(sq));if(!pt)return 0;
    Bitboard attacks=pt==PAWN ? attacks_bb<PAWN>(sq,own):attacks_bb(pt,sq,p.pieces());
    return attacks & p.pieces(~own) & ~p.pieces(PAWN);
}
static NSArray *tags(const std::string &fen,NSArray *pv) {
    Position p;std::deque<StateInfo> states(1);if(p.set(fen,false,&states.back()))return @[];
    std::set<std::string> found;
    if(p.checkers())found.insert("inCheck");
    for(auto c:{WHITE,BLACK})if(p.blockers_for_king(c)&p.pieces(c))found.insert("absolutePin");
    for(NSUInteger i=0;i<std::min(NSUInteger(7),pv.count);++i){
        Move m=UCIEngine::to_move(p,cpp(pv[i]));if(m==Move::none())break;
        bool own=i%2==0,capture=p.capture(m);Color color=p.side_to_move();auto type=type_of(p.moved_piece(m));auto old=targets(p,m.from_sq(),color);
        if(own){
            if(i==0)found.insert(std::string("first:")+names[type]);
            if(capture)found.insert("capture");
            if(m.type_of()==EN_PASSANT)found.insert("enPassant");
            if(m.type_of()==CASTLING)found.insert("castling");
            if(m.type_of()==PROMOTION){found.insert("promotion");if(m.promotion_type()!=QUEEN)found.insert("underPromotion");}
        }
        states.emplace_back();p.do_move(m,states.back(),nullptr);
        if(own){
            if(p.checkers())found.insert("check");else if(!capture)found.insert("quietMove");
            if(popcount(p.checkers())>1)found.insert("doubleCheck");
            if(p.checkers()&~square_bb(m.to_sq()))found.insert("discoveredCheck");
            auto attacked=m.type_of()==CASTLING?0:targets(p,m.to_sq(),color);
            if(popcount(attacked)>=2 && (attacked&~old)){
                found.insert("fork");found.insert(std::string("fork:")+names[type_of(p.piece_on(m.to_sq()))]);
                if((attacked&p.pieces(KING))&&(attacked&p.pieces(QUEEN)))found.insert("royalFork");
            }
            if(p.checkers() && MoveList<LEGAL>(p).size()==0){
                found.insert("checkmate");if(i==0)found.insert("mateIn1");
                if(type_of(p.piece_on(m.to_sq()))==QUEEN && p.game_ply()<12){
                    auto king=p.square<KING>(p.side_to_move());auto to=m.to_sq();
                    if((to==SQ_H4 && king==SQ_E1)||(to==SQ_H5 && king==SQ_E8))found.insert("foolsMate");
                    if(((to==SQ_F7 && king==SQ_E8)||(to==SQ_F2 && king==SQ_E1)) && (p.attackers_to(to)&p.pieces(color,BISHOP)))found.insert("scholarsMate");
                }
            }
        }
    }
    NSMutableArray *result=[NSMutableArray array];for(auto &t:found)[result addObject:str(t)];return result;
}
static NSDictionary *evaluation(const Engine::InfoFull &i) {
    std::istringstream score(UCIEngine::format_score(i.score));std::string kind;int value;score>>kind>>value;
    NSMutableArray *pv=[NSMutableArray array];std::istringstream moves(std::string(i.pv));std::string uci;while(moves>>uci)[pv addObject:str(uci)];
    return @{@"cp":kind=="cp"?@(value):NSNull.null,@"mate":kind=="mate"?@(value):NSNull.null,@"pv":pv,@"depth":@(i.depth),@"nodes":@(i.nodes)};
}
void CCStop(void){
#if defined(CC_DUAL_ENGINE) && !defined(CC_DOTPROD_VARIANT)
    if(useDotprod()){CCDotprodStop();return;}
#endif
    if(auto e=stopping.load())e->stop();
}
NSDictionary *CCChess(NSDictionary *r,NSString *networkPath){
    if([r[@"action"] isEqual:@"puzzle"])return CCPuzzle(r);
#if defined(CC_DUAL_ENGINE) && !defined(CC_DOTPROD_VARIANT)
    if(useDotprod())return CCDotprodChess(r,networkPath);
#endif
    @autoreleasepool {
        std::call_once(initialized,[]{Attacks::init();Position::init();});
        Position p;std::deque<StateInfo> states(1);std::string initial=r[@"initial"]?cpp(r[@"initial"]):StartFEN;
        if(auto e=p.set(initial,false,&states.back()))return @{@"error":str(e->what())};
        NSMutableArray *moves=[NSMutableArray array],*notations=[NSMutableArray array],*white=[NSMutableArray array],*black=[NSMutableArray array];
        NSArray *input=r[@"moves"]?:@[];bool parse=[r[@"action"] isEqual:@"parse"];
        for(NSString *token in input){
            Move m=Move::none();
            if(parse){for(auto n:MoveList<LEGAL>(p))if([normalized(str(san(p,n))) isEqual:normalized(token)]){if(m!=Move::none())return @{@"error":@"Ambiguous SAN"};m=n;}}
            else m=UCIEngine::to_move(p,cpp(token));
            if(m==Move::none())return @{@"error":@"Illegal move history"};
            std::string notation=san(p,m);[moves addObject:str(UCIEngine::move(m))];
            if(p.capture(m)){auto pc=m.type_of()==EN_PASSANT?PAWN:type_of(p.piece_on(m.to_sq()));[(p.side_to_move()==WHITE?white:black) addObject:[NSString stringWithFormat:@"%c",letters[pc]]];}
            states.emplace_back();p.do_move(m,states.back(),nullptr);
            if(p.checkers())notation+=MoveList<LEGAL>(p).size()?"+":"#";
            [notations addObject:str(notation)];
        }
        NSMutableArray *legal=[NSMutableArray array];for(auto m:MoveList<LEGAL>(p))[legal addObject:str(UCIEngine::move(m))];
        NSString *result=nil;
        if(!legal.count)result=p.checkers()?(p.side_to_move()==WHITE?@"Black wins":@"White wins"):@"Draw";
        else if(p.is_draw(0))result=@"Draw";
        else if(!p.pieces(PAWN,ROOK,QUEEN) && (popcount(p.pieces(KNIGHT,BISHOP))<=1 || (!p.pieces(KNIGHT) && (!(p.pieces(BISHOP)&DarkSquares)||!(p.pieces(BISHOP)&~DarkSquares)))))result=@"Draw";
        NSMutableDictionary *response=[@{@"fen":str(p.fen()),@"moves":moves,@"san":notations,@"legal":legal,@"turn":p.side_to_move()==WHITE?@"white":@"black",@"check":@(bool(p.checkers())),@"result":result?:NSNull.null,@"capturedWhite":white,@"capturedBlack":black,@"lastMove":moves.lastObject?:NSNull.null,@"columns":@8,@"rows":@8} mutableCopy];
        if([r[@"action"] isEqual:@"tags"]){response[@"tags"]=tags(p.fen(),r[@"pv"]?:@[]);return response;}
        bool bot=[r[@"action"] isEqual:@"bot"];
        if((![r[@"action"] isEqual:@"analyse"] && !bot) || result)return response;
        // Position parsing/move generation use local state; only the shared search engine serializes.
        std::lock_guard<std::mutex> guard(serial);
        const bool background=r[@"_backgroundEpoch"]!=nil;
        const uint64_t epoch=[r[@"_backgroundEpoch"] unsignedLongLongValue];
        if(background && epoch!=CCBackgroundEpoch())return @{@"error":@"Background search superseded"};
        if(!engine){
            if(![[NSFileManager defaultManager] fileExistsAtPath:networkPath])return @{@"error":@"Bundled engine network missing"};
            engine=std::make_unique<Engine>(std::filesystem::path(cpp(networkPath)));stopping=engine.get();
            engine->get_options().add_info_listener([](auto){});engine->set_on_start([](){});
            engine->set_on_update_no_moves([](auto&){});engine->set_on_bestmove([](auto,auto){});engine->set_on_iter([](auto&){});engine->set_on_verify_network([](auto){});
            std::istringstream option("name Hash value 64");engine->get_options().setoption(option);
        }
        std::vector<std::string> history;for(NSString *m in moves)history.push_back(cpp(m));
        if(auto e=engine->set_position(initial,history))return @{@"error":str(e->what())};
        auto setOption=[&](std::string name,std::string value){std::istringstream option("name "+name+" value "+value);engine->get_options().setoption(option);};
        // Reset strength on EVERY call: a sparring opponent must never weaken
        // the evaluator, profile analysis, or the next caller's search.
        int elo=std::max(100,std::min(3000,[r[@"elo"] intValue]));
        setOption("UCI_LimitStrength",bot && elo>=1320 ? "true":"false");
        setOption("UCI_Elo",std::to_string(std::max(1320,elo)));
        setOption("Skill Level",bot && elo<1320 ? "0":"20");
        int multipv=std::max(1,std::min(3,[r[@"multipv"] intValue]));setOption("MultiPV",std::to_string(multipv));engine->search_clear();
        std::map<usize,NSDictionary*> rows;
        engine->set_on_update_full([&](const Engine::InfoFull &i){@autoreleasepool {rows[i.multiPV]=evaluation(i);}});
        std::string chosen;
        engine->set_on_bestmove([&](auto best,auto){chosen=std::string(best);});
        Search::LimitsType limits;limits.startTime=now();limits.nodes=std::max(1000LL,std::min(8000000LL,[r[@"nodes"] longLongValue]));limits.depth=40;
        if(NSString *root=r[@"root"]){if(![legal containsObject:root])return @{@"error":@"Illegal root move"};limits.searchmoves={cpp(root)};}
        {
            std::lock_guard<std::mutex> startGuard(backgroundLock);
            if(background && epoch!=CCBackgroundEpoch()) {
                engine->set_on_update_full([](auto&){});engine->set_on_bestmove([](auto,auto){});
                return @{@"error":@"Background search superseded"};
            }
            activeBackground=background;engine->go(limits);
        }
        engine->wait_for_search_finished();
        {std::lock_guard<std::mutex> endGuard(backgroundLock);activeBackground=false;}
        engine->set_on_update_full([](auto&){});engine->set_on_bestmove([](auto,auto){});
        if(background && epoch!=CCBackgroundEpoch())return @{@"error":@"Background search superseded"};
        // Below Stockfish's supported UCI_Elo floor use its weakest skill plus
        // a deterministic lapse rate. This is a nominal sparring estimate,
        // explicitly not a calibrated site rating.
        if(bot && elo<1320 && legal.count>1){
            uint64_t h=1469598103934665603ULL;for(char c:p.fen()){h^=(unsigned char)c;h*=1099511628211ULL;}
            if(h%1000<uint64_t((1320-elo)*0.65))chosen=cpp(legal[(h>>12)%legal.count]);
        }
        NSMutableArray *evaluations=[NSMutableArray array];for(auto &pair:rows){NSMutableDictionary *row=[pair.second mutableCopy];row[@"tags"]=tags(p.fen(),row[@"pv"]);[evaluations addObject:row];}
        if(evaluations.count){
            NSArray *pv=evaluations[0][@"pv"];
            if(pv.count){Move first=UCIEngine::to_move(p,cpp(pv[0]));
                response[@"rootQuiet"]=@(first!=Move::none() && !p.capture(first) && !p.gives_check(first));}
        }
        response[@"evaluations"]=evaluations;response[@"bestmove"]=str(chosen);
        response[@"limitedStrength"]=@(bot);response[@"engine"]=@"Stockfish 19 NNUE";
#if defined(CC_DOTPROD_VARIANT)
        response[@"kernel"]=@"neon-dotprod";
#else
        response[@"kernel"]=@"neon";
#endif
        return response;
    }
}
