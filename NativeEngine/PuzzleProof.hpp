// Adapted from Chess Lab exact AND/OR prover. Rectangular, strict input validation.
#pragma once
// Exact, bounded AND/OR search. No evaluation pruning, null moves, reductions,
// or heuristic acceptance. Exhausted node budgets return UNKNOWN, never a proof.
// Initial castling rights are deliberately unsupported; generated compositions
// have none. Orthodox 8x8 pawn doubles and en passant arising in search work.
#include <functional>
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>
using namespace std;
struct Move { int a,b,prom=0; string uci()const {string s;s+=char('a'+a%8);s+=char('1'+a/8);s+=char('a'+b%8);s+=char('1'+b/8);if(prom)s+=" pnbrqk"[prom];return s;} };
struct Board {
 array<int8_t,64> p{}; int n=8,h=8,turn=1,ep=-1;
 bool inside(int f,int r)const{return f>=0&&r>=0&&f<n&&r<h;}
 bool attacked(int sq,int by)const{
  int f=sq%8,r=sq/8;
  for(int dx:{-1,1}){int x=f+dx,y=r-by;if(inside(x,y)&&p[y*8+x]==by)return true;}
  static const int kn[8][2]={{1,2},{2,1},{-1,2},{-2,1},{1,-2},{2,-1},{-1,-2},{-2,-1}};
  for(auto&d:kn){int x=f+d[0],y=r+d[1];if(inside(x,y)&&p[y*8+x]==by*2)return true;}
  for(int dx=-1;dx<=1;dx++)for(int dy=-1;dy<=1;dy++)if(dx||dy){
   int x=f+dx,y=r+dy,dist=1;
   while(inside(x,y)){int v=p[y*8+x];if(v){if(v*by>0){int t=abs(v);if(t==5||(t==6&&dist==1)||(dx&&dy?t==3:t==4))return true;}break;}x+=dx;y+=dy;dist++;}
  }return false;
 }
 int king(int side)const{for(int i=0;i<64;i++)if(p[i]==side*6)return i;return -1;}
 bool check(int side)const{int k=king(side);return k<0||attacked(k,-side);}
 Board push(Move m)const{
  Board b=*this;int piece=b.p[m.a];b.p[m.a]=0;
  if(abs(piece)==1&&m.b==ep&&!b.p[m.b]&&m.a%8!=m.b%8)b.p[m.b-8*turn]=0;
  b.p[m.b]=m.prom?turn*m.prom:piece;b.ep=-1;
  if(abs(piece)==1&&abs(m.b-m.a)==16)b.ep=(m.a+m.b)/2;
  b.turn=-turn;return b;
 }
 vector<Move> legal()const{
  vector<Move> moves;
  auto add=[&](int a,int b,int prom=0){if(p[b]*turn>0||abs(p[b])==6)return;Move m{a,b,prom};Board child=push(m);if(!child.check(turn))moves.push_back(m);};
  for(int a=0;a<64;a++)if(p[a]*turn>0){int f=a%8,r=a/8,t=abs(p[a]);
   if(t==1){for(int dx=-1;dx<=1;dx++){
     int x=f+dx,y=r+turn;if(!inside(x,y))continue;int dest=y*8+x;
     if(dx==0?p[dest]!=0:!(p[dest]*turn<0||dest==ep))continue;
     if(y==(turn==1?h-1:0)){for(int prom:{2,3,4,5})add(a,dest,prom);}else add(a,dest);
    }
    if(n==8&&h==8&&r==(turn==1?1:6)&&!p[a+8*turn]&&!p[a+16*turn])add(a,a+16*turn);
   }else if(t==2){static const int kn[8][2]={{1,2},{2,1},{-1,2},{-2,1},{1,-2},{2,-1},{-1,-2},{-2,-1}};for(auto&d:kn)if(inside(f+d[0],r+d[1]))add(a,(r+d[1])*8+f+d[0]);
   }else{for(int dx=-1;dx<=1;dx++)for(int dy=-1;dy<=1;dy++)if(dx||dy){
     if(t==3&&!(dx&&dy))continue;if(t==4&&dx&&dy)continue;
     int x=f+dx,y=r+dy;while(inside(x,y)){int dest=y*8+x;add(a,dest);if(p[dest]||t==6)break;x+=dx;y+=dy;}
   }}
  }
  sort(moves.begin(),moves.end(),[](Move a,Move b){return a.uci()<b.uci();});return moves;
 }
 string cachekey(int depth)const{string s; s.reserve(68);for(auto v:p)s+=char(v+6);s+=char(n);s+=char(h);s+=char(turn+1);s+=char(ep+1);s+=char(depth);return s;}
 int material(int side)const{static int values[]={0,1,3,3,5,9,0};int total=0;for(auto v:p)total+=(v*side>0?1:-1)*values[abs(v)];return total;}
 bool dead()const{
  int minors=0,knights=0,bishopColors=0;
  for(int sq=0;sq<64;sq++){int t=abs(p[sq]);if(t==1||t==4||t==5)return false;if(t==2){minors++;knights++;}if(t==3){minors++;bishopColors|=1<<((sq%8+sq/8)%2);}}
  return minors<=1||(!knights&&bishopColors!=3);
 }
};
Board parse(const char* fen,int columns,int rows){
 Board b;b.n=columns;b.h=rows;
 if(columns<4||columns>8||rows<4||rows>8)throw runtime_error("Invalid dimensions");
 istringstream ss(fen);string placement,turn,castle,ep;int half,full;
 if(!(ss>>placement>>turn>>castle>>ep>>half>>full)||castle!="-"||(turn!="w"&&turn!="b")||half<0||full<1)throw runtime_error("Invalid puzzle FEN");
 int f=0,r=7;string names=" pnbrqk";int kings[2]={0,0};
 for(char c:placement){if(c=='/'){if(f!=8||r==0)throw runtime_error("Invalid FEN rank");r--;f=0;}
 else if(c>='1'&&c<='8'){f+=c-'0';if(f>8)throw runtime_error("Invalid FEN width");}
 else{int pt=int(names.find(tolower(c)));if(pt<1||pt>6||!b.inside(f,r))throw runtime_error("Off-board piece");int side=isupper(c)?1:-1;b.p[r*8+f]=side*pt;if(pt==6)kings[side==1?0:1]++;if(pt==1&&(r==0||r==rows-1))throw runtime_error("Unpromoted pawn");f++;}}
 if(r!=0||f!=8||kings[0]!=1||kings[1]!=1)throw runtime_error("Invalid position");
 b.turn=turn=="w"?1:-1;
 if(ep!="-"){if(columns!=8||rows!=8||ep.size()!=2||ep[0]<'a'||ep[0]>'h'||ep[1]!=(b.turn==1?'6':'3'))throw runtime_error("Invalid en passant");b.ep=(ep[1]-'1')*8+ep[0]-'a';if(b.p[b.ep]||b.p[b.ep-8*b.turn]!=-b.turn)throw runtime_error("Invalid en passant pawn");}
 if(b.check(-b.turn))throw runtime_error("Opponent already in check");return b;
}
string fen(const Board &b){string s;for(int r=7;r>=0;r--){int empty=0;for(int f=0;f<8;f++){int v=b.p[r*8+f];if(!v)empty++;else{if(empty){s+=char('0'+empty);empty=0;}char c=" pnbrqk"[abs(v)];s+=v>0?toupper(c):c;}}if(empty)s+=char('0'+empty);if(r)s+='/';}s+=b.turn==1?" w - ":" b - ";if(b.ep>=0){s+=char('a'+b.ep%8);s+=char('1'+b.ep/8);}else s+='-';return s+" 0 1";}
struct Budget:exception{};
inline thread_local std::function<bool()> puzzleCancelled;
inline void checkPuzzleCancellation(){if(puzzleCancelled && puzzleCancelled())throw runtime_error("Background search superseded");}

struct Search {
 uint64_t nodes=0,limit;int attacker,mode=0,target=0;unordered_map<string,bool> memo;
 Search(int a,uint64_t lim,int m=0,int t=0):limit(lim),attacker(a),mode(m),target(t){memo.reserve(32768);}
 bool force(const Board&b,int depth){
  if((++nodes & 255)==0)checkPuzzleCancellation();
  if(nodes>limit)throw Budget();
  string k=b.cachekey(depth);auto it=memo.find(k);if(it!=memo.end())return it->second;
  auto moves=b.legal();bool result;
  if(b.dead())result=false;
  else if(moves.empty())result=b.turn!=attacker&&b.check(b.turn);
  else if(depth==0)result=mode==1&&b.material(attacker)>=target;
  else{
   bool own=b.turn==attacker;result=!own;
   // Ordering changes runtime only, never which moves are considered.
   stable_sort(moves.begin(),moves.end(),[&](Move a,Move c){
    auto priority=[&](Move m){Board next=b.push(m);return (next.check(next.turn)?100:0)+abs(b.p[m.b])*10+m.prom;};return priority(a)>priority(c);
   });
   for(auto m:moves){bool win=force(b.push(m),depth-1);if(own&&win){result=true;break;}if(!own&&!win){result=false;break;}}
  }
  memo.emplace(std::move(k),result);return result;
 }
 vector<Move> winners(const Board&b,int depth){vector<Move> out;for(auto m:b.legal())if(force(b.push(m),depth-1))out.push_back(m);return out;}
 int distance(const Board&b,int maxdepth){auto moves=b.legal();if(moves.empty())return b.turn!=attacker&&b.check(b.turn)?0:-1;
  for(int d=(b.turn==attacker?1:2);d<=maxdepth;d+=2)if(force(b,d))return d;return -1;
 }
 int material_value(const Board&b,int depth,int alpha=-10001,int beta=10001){
  if((++nodes & 255)==0)checkPuzzleCancellation();
  if(nodes>limit)throw Budget();
  auto moves=b.legal();if(b.dead())return -10000;
  if(moves.empty())return b.turn!=attacker&&b.check(b.turn)?10000:-10000;
  if(depth==0)return b.material(attacker);
  bool own=b.turn==attacker;int value=own?-10001:10001;
  for(auto m:moves){int v=material_value(b.push(m),depth-1,alpha,beta);if(own){value=max(value,v);alpha=max(alpha,value);}else{value=min(value,v);beta=min(beta,value);}if(alpha>=beta)break;}
  return value;
 }
 vector<Move> material_line(Board b,int depth){vector<Move> result;
  while(depth>0){auto moves=b.legal();if(moves.empty())break;bool own=b.turn==attacker;int best=own?-10001:10001;Move chosen=moves[0];
   for(auto m:moves){int value=material_value(b.push(m),depth-1);if((own&&value>best)||(!own&&value<best)){best=value;chosen=m;}}
   result.push_back(chosen);b=b.push(chosen);depth--;
  }return result;
 }
 vector<Move> line(Board b,int depth){vector<Move> result;
  while(depth>0){auto moves=b.legal();if(moves.empty())break;Move best=moves[0];int bestDist=b.turn==attacker?10000:-1;
   for(auto m:moves){Board c=b.push(m);int dist=distance(c,depth-1);if(dist<0)continue;if((b.turn==attacker&&dist<bestDist)||(b.turn!=attacker&&dist>bestDist)){best=m;bestDist=dist;}}
   if(bestDist==10000||bestDist==-1)throw runtime_error("proof line missing");result.push_back(best);b=b.push(best);depth=bestDist;
  }return result;
 }
};
string moves_json(const vector<Move>&moves){string s="[";for(size_t i=0;i<moves.size();i++){if(i)s+=",";s+='"'+moves[i].uci()+'"';}return s+"]";}
