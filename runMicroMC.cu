#include <stdlib.h>
#include <string>
#include <iostream>	
#include <sstream>
using namespace std;
#include <ctime>
#include <cuda.h>
#include <cuda_runtime.h>

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/generate.h>
#include <thrust/sequence.h>
#include <thrust/transform.h>
#include <thrust/sort.h>
#include <thrust/copy.h>
#include <thrust/fill.h>
#include <thrust/replace.h>
#include <thrust/binary_search.h>
#include <thrust/functional.h>
#include <thrust/count.h>
#include <thrust/extrema.h>
#include <thrust/iterator/iterator_traits.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/permutation_iterator.h>
#include <thrust/gather.h>
#include <thrust/unique.h>
#include <thrust/uninitialized_copy.h>
#include "realtime.cu"

#include <cusparse.h>

#include "microMC_chem.h"
#include <sys/stat.h>
#include "sys/types.h"
#include "sys/sysinfo.h"
struct sysinfo memInfo;
#include <unistd.h>

// 88 145 78

#define SIDESFILE "./table/voxelized_v6_sides_4_4_22_a.txt"
#define FILEINrun "./Input/electron_broadspectrum_2022_09_19/"
#define NFILES 99

// #define FILEINrun "./Input/data80proton/"
// #define NFILES 80

unsigned long long getTotalSystemMemory()
{
    long pages = sysconf(_SC_PHYS_PAGES);
    long page_size = sysconf(_SC_PAGE_SIZE);
    return pages * page_size;
}

struct first_element_equal_255
{
  __host__ __device__
  bool operator()(const thrust::tuple<const unsigned char&, const float&, const float&, const float&, const float&, const int&> &t)
  {
      return thrust::get<0>(t) == 255;
  }
};

void runMicroMC(ChemistrySpec *chemistrySpec, ReactionType *reactType, ParticleData *parData, int process_time, int flagDNA)
{	
	
	thrust::device_ptr<unsigned long> uniBinidxPar_dev_ptr;	
	thrust::device_vector<unsigned long> uniBinidxPar_dev_vec(MAXNUMPAR);
	if(flagDNA)
	{
/***********************************************************************************/
		int* dev_chromatinIndex;
		int* dev_chromatinStart;
		int* dev_chromatinType;
		CoorBasePair* dev_straightChrom;
		CoorBasePair* dev_segmentChrom;
		CoorBasePair* dev_bendChrom;
		float3* dev_straightHistone;
		float3* dev_bendHistone;
		float3* dev_chromosome;
		int *dev_chromosome_type;
		int totalspace = NUCLEUS_DIM*NUCLEUS_DIM*NUCLEUS_DIM_Z;
		int *chromatinIndex = (int*)malloc(sizeof(int)*totalspace);
		int *chromatinStart = (int*)malloc(sizeof(int)*totalspace);
		int *chromatinType = (int*)malloc(sizeof(int)*totalspace);
		for (int k=0; k<totalspace; k++) 
		{
			chromatinIndex[k] = -1;
			chromatinStart[k] = -1;
			chromatinType[k] = -1;
		}
		// allocating space for the segments connecting nucleosomes
		int* dev_segmentIndex;
		int* dev_segmentStart;
		int* dev_segmentType;
		int totalspace_sub = NUCLEUS_DIM*NUCLEUS_DIM*NUCLEUS_DIM_Z * 12;
		int *segmentIndex = (int*)malloc(sizeof(int)*totalspace_sub);
		int *segmentStart = (int*)malloc(sizeof(int)*totalspace_sub);
		int *segmentType = (int*)malloc(sizeof(int)*totalspace_sub);
		for (int k=0; k<totalspace_sub; k++) 
		{
			segmentIndex[k] = -1;
			segmentStart[k] = -1;
			segmentType[k] = -1;
		}
		int data[6];
		
		// X-CHROMOSOMES, there are 46 of them 
		cout << "Reading the chromosomes and types?\n";
		ifstream fin;
		fin.open("./table/chromosome_coordinates_v6.txt"); // v5 has 0,0,0 chromosome
		float fdata[3];
		// CoorBasePair *StraightChrom = (CoorBasePair*)malloc(sizeof(CoorBasePair)*STRAIGHT_BP_NUM);
		float3 *chromosome = (float3*)malloc(sizeof(float3) * NUMCHROMOSOMES);
		int *chromosome_type = (int*)malloc(sizeof(int) * NUMCHROMOSOMES);
		float ttype;
		for (int i = 0; fin >> fdata[0] >> fdata[1] >> fdata[2] >> ttype; i++) { // 46 x-chromosomes
			chromosome[i].x = fdata[0];
			chromosome[i].y = fdata[1];
			chromosome[i].z = fdata[2];
			chromosome_type[i] = ttype;
			if (i < 5) printf("%f %f %f %d\n", fdata[0], fdata[1], fdata[2], chromosome_type[i]);
		}
		fin.close();
		CUDA_CALL(cudaMalloc((void**)&dev_chromosome, NUMCHROMOSOMES * sizeof(float3)));
		CUDA_CALL(cudaMemcpy(dev_chromosome, chromosome, NUMCHROMOSOMES * sizeof(float3), cudaMemcpyHostToDevice));

		CUDA_CALL(cudaMalloc((void**)&dev_chromosome_type, NUMCHROMOSOMES * sizeof(int)));
		CUDA_CALL(cudaMemcpy(dev_chromosome_type, chromosome_type, NUMCHROMOSOMES * sizeof(int), cudaMemcpyHostToDevice));
		
		cout << "Time to read voxelized coordinates \n";
		//ifstream fin;
		// I need to figure out how to get extra coordinates
		// maybe I can store in the chromatin index as I'm not using it anyway
		fin.open(SIDESFILE);
		// ./Results/voxelized_coordinates_b_v4_connected.txt
		for (int i=0; fin >> data[0] >> data[1] >> data[2] >> data[3] >> data[4] >> data[5]; i++)
		{
			//fread(data,sizeof(int),6, pFile);
			if(i<5) printf("%d %d %d %d %d %d\n", data[0], data[1], data[2], data[3], data[4], data[5]);
			// first 3 are indicies
			if (data[3] == 0) {
				int index = data[0] + data[1] * NUCLEUS_DIM + data[2] * NUCLEUS_DIM * NUCLEUS_DIM;
				chromatinIndex[index] = data[3]; // index of the extra nucleosome ?
				chromatinStart[index] = data[4]; // bp index 200
				chromatinType[index] = data[5]; // type
			}
			else {
				// Step 1)
				// convert to voxel id first
				int x = data[0]; // segment sub voxel ids
				int y = data[1];
				int z = data[2];
				int xx = x / 4; // center voxel id
				int yy = y / 4;
				int zz = z / 4;
				int xxx = x % 4; // subvoxel coordinates
				int yyy = y % 4;
				int zzz = z % 4;
				// Step 2) Convert using 'convention'
				// convention :: we have 3 walls with 4 subvoxels each
				// numerated clockwise
				// walls xy xz yz
				// subvoxels [(0, 1), (1, 0), (0, -1), (-1, 0)]
				array <int, 2> subs[4] = {{0, 1}, {1, 0}, {0, -1}, {-1, 0}};
				// ids [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
				int subvoxel_id = 0;
				xxx -= 2; // center subvoxel
				yyy -= 2;
				zzz -= 2;
				array <int, 2> nn;
				if (zzz == -2) { // this is xy plane
					subvoxel_id += 0;
					nn = {xxx, yyy};
				}
				if (yyy == -2) { // xz
					subvoxel_id += 4;
					nn = {xxx, zzz};
				}
				if (xxx == -2) { // yz plane
					subvoxel_id += 8;
					nn = {yyy, zzz};
				}
				for (int j = 0; j < 4; j++) {
					if (nn == subs[j]) {
						subvoxel_id += j;
						break ;
					}
				}
				// index = x + y * NUCLEUS_DIM + z * NUCLEUS_DIM * NUCLEUS_DIM; // current id of the voxel
				int index = xx + yy * NUCLEUS_DIM + zz * NUCLEUS_DIM * NUCLEUS_DIM;
				int sub_index = index * 12; // shifted index to accommodate 12 subvoxels
				sub_index += subvoxel_id;
				// [544.5, 170.5, 93.5]
				// if ((float)xx * 11 + 5.5 == 544.5 && 
				// 	(float)yy * 11 + 5.5 == 170.5 &&
				// 	(float)zz * 11 + 5.5 == 93.5) {
				// 	cout << "index :: " << index << " " << xx << " " << yy << " " << zz << endl;
				// 	cout << "ID of a segment and type = " << sub_index << " " << data[3] << " " << data[4] << " " << data[5] << endl;
				// }
				segmentIndex[sub_index] = data[3]; // future chromosome ID
				segmentStart[sub_index] = data[4]; // segment base pair start
				segmentType[sub_index] = data[5]; // type orientation
			}
		}
		fin.close();
		cout << "end of reading voxelized coordinates \n\n";
		CUDA_CALL(cudaMalloc((void**)&dev_chromatinIndex, totalspace * sizeof(int)));
		CUDA_CALL(cudaMemcpy(dev_chromatinIndex, chromatinIndex, totalspace * sizeof(int), cudaMemcpyHostToDevice));//DNA index
		CUDA_CALL(cudaMalloc((void**)&dev_chromatinStart, totalspace * sizeof(int)));
		CUDA_CALL(cudaMemcpy(dev_chromatinStart, chromatinStart, totalspace * sizeof(int), cudaMemcpyHostToDevice));//# of start base in the box
		CUDA_CALL(cudaMalloc((void**)&dev_chromatinType, totalspace * sizeof(int)));
		CUDA_CALL(cudaMemcpy(dev_chromatinType, chromatinType, totalspace * sizeof(int), cudaMemcpyHostToDevice));//type of the DNA in the box
	    free(chromatinIndex);
	    free(chromatinStart);
	    free(chromatinType);
		// copying all segments into CUDA
		CUDA_CALL(cudaMalloc((void**)&dev_segmentIndex, totalspace_sub * sizeof(int)));
		CUDA_CALL(cudaMemcpy(dev_segmentIndex, segmentIndex, totalspace_sub * sizeof(int), cudaMemcpyHostToDevice));//DNA index
		CUDA_CALL(cudaMalloc((void**)&dev_segmentStart, totalspace_sub * sizeof(int)));
		CUDA_CALL(cudaMemcpy(dev_segmentStart, segmentStart, totalspace_sub * sizeof(int), cudaMemcpyHostToDevice));//# of start base in the box
		CUDA_CALL(cudaMalloc((void**)&dev_segmentType, totalspace_sub * sizeof(int)));
		CUDA_CALL(cudaMemcpy(dev_segmentType, segmentType, totalspace_sub * sizeof(int), cudaMemcpyHostToDevice));//type of the DNA in the box
	    free(segmentIndex);
	    free(segmentStart);
	    free(segmentType);
		// end copying segments
		// Loading segment template
		CoorBasePair *SegmentChrom = (CoorBasePair*)malloc(sizeof(CoorBasePair)*SEGMENT_BP_NUM);
		const char *segment = "./table/NucleosomeTableSegment.txt";
		printf("Straight Chromatin Table: Reading %s\n", segment);
		FILE *fpSegment = fopen(segment,"r");
		float dump_float;
    	int dump;
		float bx, by, bz, rx, ry, rz, lx, ly, lz;
	    for (int i=0; i<SEGMENT_BP_NUM; i++)
		{
		    fscanf(fpSegment,"%f %f %f %f %f %f %f %f %f %f\n", &dump_float, &bx, &by, &bz, &rx, &ry, &rz, &lx, &ly, &lz);
			dump = dump_float;
			//if(i<5) printf("%d %f %f %f %f %f %f %f %f %f\n", dump, bx, by, bz, rx, ry, rz, lx, ly, lz);
			SegmentChrom[i].base.x = bx;
			SegmentChrom[i].base.y = by;
			SegmentChrom[i].base.z = bz;
			SegmentChrom[i].right.x = rx;
			SegmentChrom[i].right.y = ry;
			SegmentChrom[i].right.z = rz;
			SegmentChrom[i].left.x = lx;
			SegmentChrom[i].left.y = ly;
			SegmentChrom[i].left.z = lz;
		}
		fclose(fpSegment);
		CUDA_CALL(cudaMalloc((void**)&dev_segmentChrom, SEGMENT_BP_NUM * sizeof(CoorBasePair)));
		CUDA_CALL(cudaMemcpy(dev_segmentChrom, SegmentChrom, SEGMENT_BP_NUM * sizeof(CoorBasePair), cudaMemcpyHostToDevice));
		//

		CoorBasePair *StraightChrom = (CoorBasePair*)malloc(sizeof(CoorBasePair)*STRAIGHT_BP_NUM);
		const char *straight = "./table/NucleosomeTable200StraightZ.txt";
		printf("Straight Chromatin Table: Reading %s\n", straight);
		FILE *fpStraight = fopen(straight,"r");
		// float dump_float;
    	// int dump;
		// float bx, by, bz, rx, ry, rz, lx, ly, lz;
	    for (int i=0; i<STRAIGHT_BP_NUM; i++)
		{
		    fscanf(fpStraight,"%f %f %f %f %f %f %f %f %f %f\n", &dump_float, &bx, &by, &bz, &rx, &ry, &rz, &lx, &ly, &lz);
			dump = dump_float;
			//if(i<5) printf("%d %f %f %f %f %f %f %f %f %f\n", dump, bx, by, bz, rx, ry, rz, lx, ly, lz);
			StraightChrom[i].base.x = bx;
			StraightChrom[i].base.y = by;
			StraightChrom[i].base.z = bz;
			StraightChrom[i].right.x = rx;
			StraightChrom[i].right.y = ry;
			StraightChrom[i].right.z = rz;
			StraightChrom[i].left.x = lx;
			StraightChrom[i].left.y = ly;
			StraightChrom[i].left.z = lz;
		}
		fclose(fpStraight);
		CUDA_CALL(cudaMalloc((void**)&dev_straightChrom, STRAIGHT_BP_NUM * sizeof(CoorBasePair)));
		CUDA_CALL(cudaMemcpy(dev_straightChrom, StraightChrom, STRAIGHT_BP_NUM * sizeof(CoorBasePair), cudaMemcpyHostToDevice));

		CoorBasePair *BendChrom = (CoorBasePair*)malloc(sizeof(CoorBasePair)*BEND_BP_NUM);
		const char *bend = "./table/NucleosomeTable200SideZ.txt";
		printf("Bend Chromatin Table: Reading %s\n", bend);
		FILE *fpBend = fopen(bend,"r");
	    for (int i=0; i<BEND_BP_NUM; i++)
		{
		    fscanf(fpStraight,"%f %f %f %f %f %f %f %f %f %f\n", &dump_float, &bx, &by, &bz, &rx, &ry, &rz, &lx, &ly, &lz);
			dump = dump_float;
			//if(i<5) printf("%d %f %f %f %f %f %f %f %f %f\n", dump, bx, by, bz, rx, ry, rz, lx, ly, lz);
			BendChrom[i].base.x = bx;
			BendChrom[i].base.y = by;
			BendChrom[i].base.z = bz;
			BendChrom[i].right.x = rx;
			BendChrom[i].right.y = ry;
			BendChrom[i].right.z = rz;
			BendChrom[i].left.x = lx;
			BendChrom[i].left.y = ly;
			BendChrom[i].left.z = lz;
		}
		fclose(fpBend);
		CUDA_CALL(cudaMalloc((void**)&dev_bendChrom, BEND_BP_NUM * sizeof(CoorBasePair)));
		CUDA_CALL(cudaMemcpy(dev_bendChrom, BendChrom, BEND_BP_NUM * sizeof(CoorBasePair), cudaMemcpyHostToDevice));
		
		float hisx, hisy, hisz;
		float3* bendHistone = (float3*)malloc(sizeof(float3)*BEND_HISTONE_NUM);
		// file artifacts that containt nothing important
		const char *bent = "./table/BentHistonesTable1.txt";
		printf("Bent Histone Table: Reading %s\n", bent);
		FILE *fpBentH = fopen(bent,"r");
	    for (int i=0; i<BEND_HISTONE_NUM; i++)
		{
		    fscanf(fpBentH,"%f %f %f\n", &hisx, &hisy, &hisz);
		    //if(i<5) printf("%f %f %f\n", hisx, hisy, hisz);
			bendHistone[i].x = hisx;
			bendHistone[i].y = hisy;
			bendHistone[i].z = hisz;
		}
		fclose(fpBentH);
		CUDA_CALL(cudaMalloc((void**)&dev_bendHistone, BEND_HISTONE_NUM * sizeof(float3)));
		CUDA_CALL(cudaMemcpy(dev_bendHistone, bendHistone, BEND_HISTONE_NUM * sizeof(float3), cudaMemcpyHostToDevice));
		
		float3 *straightHistone = (float3*)malloc(sizeof(float3)*STRAIGHT_HISTONE_NUM);
		// file artifacts that contain nothing important
		const char *straiHistone = "./table/StraightHistonesTable1.txt";
		printf("Straight Histone Table: Reading %s\n", straiHistone);
		FILE *fpStraiH = fopen(straiHistone,"r");
	    for (int i=0; i<STRAIGHT_HISTONE_NUM; i++)
		{
		    fscanf(fpStraiH,"%f %f %f\n", &hisx, &hisy, &hisz);
		    //if(i<5) printf("%f %f %f\n", hisx, hisy, hisz);
			straightHistone[i].x = hisx;
			straightHistone[i].y = hisy;
			straightHistone[i].z = hisz;
		}
		fclose(fpStraiH);
		CUDA_CALL(cudaMalloc((void**)&dev_straightHistone, STRAIGHT_HISTONE_NUM * sizeof(float3)));
		CUDA_CALL(cudaMemcpy(dev_straightHistone, straightHistone, STRAIGHT_HISTONE_NUM * sizeof(float3), cudaMemcpyHostToDevice));
		
		free(StraightChrom);
		free(BendChrom);	
		free(bendHistone);	
		free(straightHistone);

		//modelTableSetup(dev_chromatinIndex,dev_chromatinStart,dev_chromatinType,dev_straightChrom,dev_bendChrom,dev_straightHistone,dev_bendHistone);
		printf("DNA geometry has been loaded to GPU memory\n");	 
		int* tmp=(int*) malloc(sizeof(int)*27);
		int kk=0;	
		for(int iz = -1; iz < 2; iz ++)
	    {
	        for(int iy = -1; iy < 2; iy ++)
	        {
		        for(int ix = -1; ix < 2; ix ++)
				{
					tmp[kk] = iz * NUCLEUS_DIM * NUCLEUS_DIM + iy * NUCLEUS_DIM + ix;
					//printf("idx_neig = %d, iz = %d, iy = %d, iz = %d, h_deltaidxBin_neig = %d\n", idx_neig, iz, iy, ix, tmp[idx_neig]);
					kk++;
				}
			}
		}
		CUDA_CALL(cudaMemcpyToSymbol(neighborindex,tmp,sizeof(int)*27,0,cudaMemcpyHostToDevice));
		free(tmp);
		printf("Finish initialize neighborindex\n");

		calDNAreact_radius(rDNA,h_deltaT);//calculate reaction radius
		CUDA_CALL(cudaMemcpyToSymbol(d_rDNA,rDNA,sizeof(float)*6, 0, cudaMemcpyHostToDevice));
/********deal with total physics energy deposit*************************************/
				// CUDA Error at runMicroMC.cu:834
		int tot_shuffled = NFILES;
		int *shuffled = (int*)malloc(sizeof(int) * tot_shuffled);
		for (int ii = 0; ii < tot_shuffled; ii++) shuffled[ii] = ii + 1;
		for (int statistics = 1; statistics <= 1; statistics++) { // number of times running files
		// Gy to match ground Truth data, 
		// FILE* fp_record = fopen("./Results/totalrecordMeta.txt","a");
		
		for (int numFiles = tot_shuffled; numFiles <= tot_shuffled; numFiles += 100) { // number of files to test
			
			for (int ii = 0; ii < tot_shuffled; ii++) {
				// this works: swap(a[i], a[rand() % a.size()]); // can swap with itself
				swap(shuffled[ii], shuffled[ii + rand() % (tot_shuffled - ii)]);    
			}
			// shuffled[0] = 2; // <- for testing only, remove afterwards
			double phyEne = 0.0;
			for (int shuffle_id = 0; shuffle_id < numFiles; shuffle_id++) { // 
				int file_id = shuffled[shuffle_id];
				ifstream infile;
				// string input = "./Input/data80proton/" +to_string(file_id) + "/phyEne.txt"; 
				// string input = "./Input/data53electron/" +to_string(file_id) + "/phyEne.txt"; 
				string input = FILEINrun + to_string(file_id) + "/phyEne.txt";
			
				infile.open(input);
				double x, y;
				infile >> x >> y;
				phyEne += y;
				infile.close();
					// printf("physics results: Reading %s\n", input.c_str());
			}	
			cout << "!!!!!!!!!!!!!!!!! phyEne :: " << phyEne << endl;
			chemReact* totalrecord = NULL;
			// int x, y, z, w;//chromosome index, base index, left or right, damage type
			int cur_len_totalrecord = 0, add_len_totalrecord;
			for (int shuffle_id = 0; shuffle_id < numFiles; shuffle_id++) {
				int totalphy = 0;
				int file_id = shuffled[shuffle_id];
				Edeposit* edrop = readStage(&totalphy, 0, file_id);//read binary file x y z e
				// printf("\n**********\ntotal initial number of physics energy deposit point is %d\n**********\n", totalphy);

				Edeposit* dev_edrop;
				cudaMalloc((void**)&dev_edrop,totalphy*sizeof(Edeposit));
				cudaMemcpy(dev_edrop, edrop, totalphy*sizeof(Edeposit), cudaMemcpyHostToDevice);
				free(edrop);
				
				combinePhysics* d_recorde;
				CUDA_CALL(cudaMalloc((void**)&d_recorde,sizeof(combinePhysics)*totalphy));

				

				phySearch<<<(MAXNUMPAR-1)/NTHREAD_PER_BLOCK_PAR+1,NTHREAD_PER_BLOCK_PAR>>>(totalphy, dev_edrop, 
					dev_chromatinIndex,dev_chromatinStart,dev_chromatinType, dev_straightChrom, dev_segmentChrom,
											dev_bendChrom, dev_straightHistone, dev_bendHistone, d_recorde,
											dev_chromosome, dev_chromosome_type,
										dev_segmentIndex, dev_segmentStart, dev_segmentType);
				
				CUDA_CALL(cudaFree(dev_edrop));
				cudaDeviceSynchronize();

				combinePhysics* recorde=(combinePhysics*)malloc(sizeof(combinePhysics)*totalphy);		 
				CUDA_CALL(cudaMemcpy(recorde, d_recorde, sizeof(combinePhysics)*totalphy,cudaMemcpyDeviceToHost));

				chemReact* recordPhy = combinePhy(&totalphy, recorde, 0, file_id);//consider the probability and generate final damage site
				// printf("\n**********\neffective physics damage is %d\n**********", totalphy);
				free(recorde);
				CUDA_CALL(cudaFree(d_recorde));
			/**************************************************************/
				int totalchem = 0;
				Edeposit* chemdrop=readStage(&totalchem, 1, file_id);
				// printf("\n**********\ntotal initial number of chemical  point is %d\n**********\n", totalchem);

				Edeposit* dev_chemdrop;
				cudaMalloc((void**)&dev_chemdrop, totalchem*sizeof(Edeposit));
				cudaMemcpy(dev_chemdrop, chemdrop, totalchem*sizeof(Edeposit), cudaMemcpyHostToDevice);
				free(chemdrop);
				combinePhysics* d_recordc;
				CUDA_CALL(cudaMalloc((void**)&d_recordc,sizeof(combinePhysics)*totalchem));

				chemSearch<<<(MAXNUMPAR-1)/NTHREAD_PER_BLOCK_PAR+1,NTHREAD_PER_BLOCK_PAR>>>(totalchem, dev_chemdrop, 
					dev_chromatinIndex,dev_chromatinStart,dev_chromatinType, dev_straightChrom, dev_segmentChrom,
											dev_bendChrom, dev_straightHistone, dev_bendHistone, d_recordc,
											dev_chromosome, dev_chromosome_type,
											dev_segmentIndex, dev_segmentStart, dev_segmentType);
				CUDA_CALL(cudaFree(dev_chemdrop));
				cudaDeviceSynchronize();

				combinePhysics* recordc=(combinePhysics*)malloc(sizeof(combinePhysics)*totalchem);		 
				CUDA_CALL(cudaMemcpy(recordc, d_recordc, sizeof(combinePhysics)*totalchem,cudaMemcpyDeviceToHost));
				
				// not run this
				chemReact* recordChem = combinePhy(&totalchem, recordc, 1, file_id);//consider the probability and generate final damage site
				// filtered under threshold

				// printf("\n**********\neffective chemical damage is %d\n**********", totalchem);
				free(recordc);
				CUDA_CALL(cudaFree(d_recordc));
				// string input = "./Results/data3000/totalrecordMetaAll" + to_string(file_id) + ".txt";
				// cout << input << endl;
				// ofstream fout(input.c_str());
				
				if (totalphy + totalchem == 0) { printf("NO DAMAGE AT ALL %d\n", file_id); continue ; }
				add_len_totalrecord = totalphy + totalchem;
				cout << "cur and add :: " << cur_len_totalrecord << " " << add_len_totalrecord << endl;
				totalrecord=(chemReact*)realloc(totalrecord, // realloc!!!!!!!!!!!
					sizeof(chemReact)*(cur_len_totalrecord + add_len_totalrecord));
				// cout << "still hit\n";
				cout << "File in question :: " << file_id << endl;
				cout << "still hit\n";
				memcpy(&totalrecord[cur_len_totalrecord], recordPhy, sizeof(chemReact)*totalphy);
				memcpy(&totalrecord[cur_len_totalrecord + totalphy], recordChem, sizeof(chemReact)*totalchem);
				cur_len_totalrecord += add_len_totalrecord;
				free(recordPhy);
				free(recordChem);	    
				// cout << "!!!!!!!!!!!!!!!!! phyEne :: " << phyEne << endl;
				
				// printf("total effective is %d\n**********", totalphy+totalchem);	
				// save them all first 
			}	 // end of shuffle_id
			double pho=997; // %kg/m^3
			double L=110e-6; //%m
			double W=11e-6; // %m
			double mass=pho*L*L*W; //%kg
			double E_ev=phyEne; // %eV
			double ratio=1.602177e-19; // %J/ev
			double E_J=E_ev*ratio;
			double dose=E_J/mass; //%Gy, the result is around 1.2 nGy from 1 eV energy deposition

			cout << "Gy TOTAL dose for files: " << numFiles << " :: dose = " << dose << endl;
			damageAnalysis(cur_len_totalrecord, totalrecord, numFiles, dose);
			free(totalrecord);//*/
			size_t free_mem, total_mem;
			cudaMemGetInfo(&free_mem, &total_mem);
			cout << "MEMORY :: ***************************************\n";
			cout << "MEMORY :: ***************************************\n";
			cout << "MEMORY :: ***************************************\n";
			cout << "CUDA FREE :: " << (free_mem >> 23) << "MB   TOTAL :: " << (total_mem >> 23) << "MB" << endl;
			sysinfo(&memInfo);
			long long totalPhysMem = memInfo.totalram;
			//Multiply in next statement to avoid int overflow on right hand side...
			totalPhysMem *= memInfo.mem_unit;
			long long physMemUsed = memInfo.totalram - memInfo.freeram;
			//Multiply in next statement to avoid int overflow on right hand side...
			physMemUsed *= memInfo.mem_unit;
			cout << "Total Memory :: " << (getTotalSystemMemory() >> 30) << "Gb" << endl;
			cout << "USED CPU :: " << (physMemUsed >> 20) << "Mb  Total CPU :: " << (totalPhysMem >> 20) << "Mb\n\n\n\n" << endl;
		} // end of for numFiles
		// fclose(fp_record);
		// some random comment to check kbs
		cout << "Statistics :: " << statistics << endl;
		} // end of for statistics 
		free(shuffled);
		CUDA_CALL(cudaFree(dev_segmentIndex));
		CUDA_CALL(cudaFree(dev_segmentStart));
		CUDA_CALL(cudaFree(dev_segmentType));
	    CUDA_CALL(cudaFree(dev_chromatinIndex));	
		CUDA_CALL(cudaFree(dev_chromatinType));
		CUDA_CALL(cudaFree(dev_chromatinStart));
		CUDA_CALL(cudaFree(dev_straightHistone));
		CUDA_CALL(cudaFree(dev_straightChrom));
		CUDA_CALL(cudaFree(dev_bendHistone));
		CUDA_CALL(cudaFree(dev_bendChrom));
		CUDA_CALL(cudaFree(dev_segmentChrom));
		CUDA_CALL(cudaFree(dev_chromosome));
		CUDA_CALL(cudaFree(dev_chromosome_type));
	} // end of if flagDNA
	uniBinidxPar_dev_vec.clear();	
}
