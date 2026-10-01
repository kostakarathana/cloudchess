#pragma once
#include "PuzzleProof.hpp"
#include <cmath>
#include <limits>

// Measurement only: no learned score or fallible bot participates in legality,
// forced-mate certification, acceptable answers, or the opponent's proof line.
namespace Challenge {
constexpr const char *version="challenge-v2";
struct Probe {
    vector<Move> moves;
    vector<int> scores;
    int depth=0;
    uint64_t nodes=0;
};
struct Bot {
    uint64_t nodes=0,limit;
    explicit Bot(uint64_t budget):limit(budget){}
    static int evaluate(const Board& b) {
        static const int value[]={0,100,320,335,500,900,0};int score=0;
        for(int s=0;s<64;s++)if(b.p[s]) {
            int side=b.p[s]>0?1:-1,t=abs(b.p[s]),f=s%8,r=s/8;
            int centre=int(14*(1-abs(2.0*f-(b.n-1))/b.n)+14*(1-abs(2.0*r-(b.h-1))/b.h));
            int positional=t==1?8*(side==1?r:b.h-1-r):t==2||t==3?centre:t==6?-centre/3:centre/4;
            score+=side*(value[t]+positional);
        }
        return score*b.turn;
    }
    static int order(const Board&b,Move m) {
        static const int v[]={0,100,320,335,500,900,0};
        int capture=abs(b.p[m.b]);if(!capture&&abs(b.p[m.a])==1&&m.b==b.ep)capture=1;
        return 10*v[capture]-v[abs(b.p[m.a])]+(m.prom?v[m.prom]:0);
    }
    int search(const Board& b,int depth,int alpha,int beta,int ply) {
        if((++nodes & 255)==0)checkPuzzleCancellation();
        if(nodes>limit)throw Budget();
        auto moves=b.legal();
        if(moves.empty())return b.check(b.turn)?-30000+ply:0;
        if(b.dead())return 0;
        if(depth==0)return evaluate(b);
        stable_sort(moves.begin(),moves.end(),[&](Move a,Move c){return order(b,a)>order(b,c);});
        int best=-32000;
        for(auto m:moves){int value=-search(b.push(m),depth-1,-beta,-alpha,ply+1);best=max(best,value);alpha=max(alpha,value);if(alpha>=beta)break;}
        return best;
    }
    Probe run(const Board& b,int maxDepth) {
        Probe out;out.moves=b.legal();
        // Complete every root score at each depth. If a node budget runs out,
        // discard the partial iteration rather than favour early UCI moves.
        for(int d=1;d<=maxDepth;d++) {
            vector<int> scores;
            try {for(auto m:out.moves)scores.push_back(-search(b.push(m),d-1,-32000,32000,1));}
            catch(Budget&){break;}
            out.scores=std::move(scores);out.depth=d;
        }
        out.nodes=nodes;return out;
    }
};
inline const vector<string>& names() {
    static const vector<string> n={"area","aspect","pieces","ownP","ownN","ownB","ownR","ownQ","enemyP","enemyN","enemyB","enemyR","enemyQ","balance","inCheck","turns","plies","mateEnd","firstChoices","meanChoices","maxChoices","meanDefenses","maxDefenses","checks","captures","quiet","sacrifices","distance","firstCheck","firstCapture","firstPromotion",
        "bot1RootRank","bot1RootGap","bot1MeanRank","bot1WorstGap","bot1Surprisal","bot1Depth","bot1Entropy",
        "bot2RootRank","bot2RootGap","bot2MeanRank","bot2WorstGap","bot2Surprisal","bot2Depth","bot2Entropy",
        "bot4RootRank","bot4RootGap","bot4MeanRank","bot4WorstGap","bot4Surprisal","bot4Depth","bot4Entropy"};return n;
}
struct Measurement {vector<double> x;vector<double> success;uint64_t nodes=0;};
inline Measurement measure(Board board,const vector<string>& line) {
    if(line.empty()||line.size()>16)throw runtime_error("Invalid difficulty line");
    Measurement out;auto&x=out.x;x.assign(names().size(),0);out.success.assign(3,1);
    int side=board.turn;x[0]=board.n*board.h;x[1]=double(max(board.n,board.h))/min(board.n,board.h);
    for(auto p:board.p)if(p){x[2]++;if(abs(p)!=6)x[(p*side>0?3:8)+abs(p)-1]++;}
    x[13]=board.material(side);x[14]=board.check(side);x[16]=line.size();
    double own=0,def=0;int measured=0;
    for(size_t i=0;i<line.size();i++) {
        auto legal=board.legal();auto it=find_if(legal.begin(),legal.end(),[&](Move m){return m.uci()==line[i];});
        if(it==legal.end())throw runtime_error("Illegal difficulty line");
        Move correct=*it;Board next=board.push(correct);
        if(i%2==0) {
            own++;x[18]=i==0?legal.size():x[18];x[19]+=legal.size();x[20]=max(x[20],double(legal.size()));
            bool capture=board.p[correct.b]||(abs(board.p[correct.a])==1&&correct.b==board.ep),check=next.check(next.turn);
            x[23]+=check;x[24]+=capture;x[25]+=!capture&&!check;
            x[26]+=next.attacked(correct.b,next.turn)&&abs(board.p[correct.a])>abs(board.p[correct.b]);
            x[27]+=double(max(abs(correct.a%8-correct.b%8),abs(correct.a/8-correct.b/8)))/max(board.n-1,board.h-1);
            if(i==0){x[28]=check;x[29]=capture;x[30]=correct.prom!=0;}
            // First three solver decisions bound phone cost. Remaining line
            // structure still enters the model; bots never see the answer.
            if(measured<3) {
                const int depths[]={1,2,4};const uint64_t budgets[]={256,1400,6000};const double temperatures[]={180,90,35};
                for(int k=0;k<3;k++) {
                    Bot bot(budgets[k]);auto p=bot.run(board,depths[k]);out.nodes+=p.nodes;
                    if(p.depth==0)throw runtime_error("No completed difficulty probe");
                    int index=int(it-legal.begin()),score=p.scores[index],best=*max_element(p.scores.begin(),p.scores.end());
                    // Mates in one can have multiple equivalent human solutions.
                    // Count any mating root here; no label is leaked to search.
                    vector<bool> accepted(p.moves.size(),false);accepted[index]=true;
                    if(next.legal().empty()&&next.check(next.turn))for(size_t j=0;j<p.moves.size();j++){Board c=board.push(p.moves[j]);accepted[j]=c.check(c.turn)&&c.legal().empty();}
                    int higher=0;double denom=0,numer=0,entropy=0;vector<double> weights;
                    for(size_t j=0;j<p.scores.size();j++) {
                        higher+=p.scores[j]>score;
                        double w=exp(max(-40.0,double(p.scores[j]-best)/temperatures[k]));weights.push_back(w);denom+=w;if(accepted[j])numer+=w;
                    }
                    for(double w:weights){double q=w/denom;if(q>0)entropy-=q*log(q);}
                    double rank=double(higher)/max(size_t(1),p.moves.size()-1),gap=min(20.0,max(0.0,double(best-score)/100));
                    int start=31+7*k;
                    if(measured==0){x[start]=rank;x[start+1]=gap;}
                    x[start+2]+=rank;x[start+3]=max(x[start+3],gap);x[start+4]+=-log(max(1e-9,numer/denom));x[start+5]+=p.depth;x[start+6]+=entropy;
                    out.success[k]*=numer/denom;
                }
                measured++;
            }
        }else{def++;x[21]+=legal.size();x[22]=max(x[22],double(legal.size()));}
        board=next;
    }
    x[15]=own;x[17]=board.check(board.turn)&&board.legal().empty();x[19]/=max(1.0,own);x[21]/=max(1.0,def);x[27]/=max(1.0,own);
    for(int k=0;k<3;k++){x[33+7*k]/=max(1,measured);x[36+7*k]/=max(1,measured);x[37+7*k]/=max(1,measured);}
    return out;
}
}
