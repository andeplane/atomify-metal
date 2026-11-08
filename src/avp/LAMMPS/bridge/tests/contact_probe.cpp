// Real AIREBO contact regression: no atom loss or original bond-distance changes.
#include "atomify_lammps.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
int main(int argc,char**argv){
 if(argc!=4)return 2;
 const int steps=std::atoi(argv[3]); if(steps<1||steps>100)return 2;
 auto*s=atomify_sim_create(0);atomify_sim_set_publish_interval(s,0);
 if(atomify_sim_run_file(s,argv[1])!=ATOMIFY_OK){std::fprintf(stderr,"%s\n",atomify_sim_last_error(s));return 3;}
 double peak=0;
 for(int frame=0;frame<180;frame++){
  double x=-4+8*std::min(frame,90)/90.0;
  if(frame>90)x=4-8*(frame-90)/90.0;
  std::vector<atomify_force_sphere> spheres;
  if(std::strcmp(argv[2],"overlap")==0){for(int j=0;j<6;j++)spheres.push_back({{x,0.03*j,0},1.1,1});}
  else if(std::strcmp(argv[2],"deep")==0)spheres.push_back({{1.397,0,0},1.1,1});
  else if(std::strcmp(argv[2],"tracking")==0){if(frame%30<15)spheres.push_back({{1.397,0,0},1.1,1});}
  else spheres.push_back({{x,0,0},1.1,1});
  atomify_sim_set_force_spheres(s,spheres.data(),(int)spheres.size());
  char command[32];std::snprintf(command,sizeof(command),"run %d",steps);
  if(atomify_sim_command(s,command)!=ATOMIFY_OK){std::fprintf(stderr,"frame=%d %s\n",frame,atomify_sim_last_error(s));return 4;}
  atomify_snapshot a;if(!atomify_sim_snapshot_lock(s,&a))return 5;peak=std::max(peak,a.temperature);atomify_sim_snapshot_unlock(s);
 }
 atomify_sim_set_force_spheres(s,nullptr,0);
 if(atomify_sim_command(s,"run 20000")!=ATOMIFY_OK){std::fprintf(stderr,"release %s\n",atomify_sim_last_error(s));return 6;}
 atomify_snapshot a;atomify_sim_snapshot_lock(s,&a);
 bool connected=true;for(int i=0;i<6;i++){
  double cc=0,ch=0;for(int k=0;k<3;k++){cc=std::hypot(cc,a.positions[3*i+k]-a.positions[3*((i+1)%6)+k]);ch=std::hypot(ch,a.positions[3*i+k]-a.positions[3*(i+6)+k]);}
  connected&=cc<1.85&&ch<1.3;
 }
 std::printf("case=%s cadence_steps=%d atoms=%d max_temperature=%g final_temperature=%g original_connectivity=%d\n",argv[2],steps,a.natoms,peak,a.temperature,connected);
 atomify_sim_snapshot_unlock(s);atomify_sim_destroy(s);return connected?0:7;
}
